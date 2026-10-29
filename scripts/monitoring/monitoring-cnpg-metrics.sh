#!/usr/bin/env bash
# monitoring-cnpg-metrics.sh - applies the PostgreSQL PodMonitor and checks the primary's metrics.
#
# Stage M2 told Prometheus to read the PostgreSQL metrics, using a
# PodMonitor (a Kubernetes object that names the pods and the port
# Prometheus reads). This script asks Flux to apply it now and then reads
# the metrics of the primary itself, through a port-forward, to see that
# they are there.
#
# It shows the metrics the alerts use: whether PostgreSQL is up, the
# replication, and the backup timestamps that the Barman Cloud plugin
# publishes. It changes nothing apart from the Flux step and restarts no
# pod. Run it again only when you change the PostgreSQL monitoring.
#
# Run it: bash scripts/monitoring/monitoring-cnpg-metrics.sh (after git push of the PodMonitor; stage M2)
# Changes the cluster: no. It asks Flux to apply what is in Git now; then it
#   only reads (no pod restarts). Prints no secrets.
#
# What it does:
#   1. Lets Flux apply the PodMonitor.
#        flux reconcile kustomization apps-monitoring
#   2. Reads the metrics of the primary through a port-forward (enters the pod
#      directly, so no NetworkPolicy is involved):
#        kubectl -n databases port-forward pod/<primary> 19187:9187
#        curl http://127.0.0.1:19187/metrics
#   3. Shows the metrics needed for the alerts in M4: exporter up, replication,
#      backup timestamps (Barman Cloud plugin).
#   4. Shows the Prometheus target state (down until M3 adds the
#      NetworkPolicy that lets Prometheus reach port 9187).
#
# What you should see: PASS for the PodMonitor, "exporter answers",
#   cnpg_collector_up 1 and the Barman Cloud backup metrics, then
#   "RESULT M2 CloudNativePG passed".
# If it fails: "port-forward ... did not start": check the primary pod with
#   kubectl -n databases get pods.
# Needs: flux, kubectl, curl, jq.
set -uo pipefail

NS=databases
FAILS=0
ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

TMP=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

# forward <namespace> <target> <local:remote>: background port-forward, waits until it listens
forward() {
  kubectl -n "$1" port-forward "$2" "$3" >/dev/null 2>&1 &
  PIDS+=($!)
  local port=${3%%:*}
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$port/" && return 0; sleep 1; done
  return 1
}

echo "==> 1. PodMonitor"
flux reconcile source git flux-system
flux reconcile kustomization apps-monitoring
kubectl -n monitoring get podmonitor pg-openbao >/dev/null 2>&1 && pass "PodMonitor monitoring/pg-openbao exists" \
  || fail "PodMonitor monitoring/pg-openbao missing"

echo
PRIMARY=$(kubectl -n "$NS" get cluster pg-openbao -o jsonpath='{.status.currentPrimary}')
echo "==> 2. Metrics from the primary $PRIMARY (port-forward 19187 -> 9187)"
if forward "$NS" "pod/$PRIMARY" 19187:9187; then
  code=$(curl -s -o "$TMP/metrics" -w '%{http_code}' http://127.0.0.1:19187/metrics)
  info "GET :9187/metrics -> HTTP $code, $(grep -vc '^#' "$TMP/metrics") sample lines"
  [[ $code == 200 ]] && pass "exporter answers" || fail "exporter HTTP $code"
  grep -v '^#' "$TMP/metrics" | sed 's/[{ ].*//' | sort -u > "$TMP/names"
  info "distinct metric names: $(wc -l < "$TMP/names")"

  echo
  echo "==> 3. Metrics for the alerts (M4)"
  grep -q '^cnpg_collector_up' "$TMP/metrics" && pass "$(grep '^cnpg_collector_up' "$TMP/metrics")" \
    || fail "cnpg_collector_up missing"
  if grep -q 'barman_cloud_cloudnative_pg_io_last_available_backup_timestamp' "$TMP/names"; then
    pass "Barman Cloud plugin backup metrics present:"
    grep -v '^#' "$TMP/metrics" | grep 'barman_cloud' | sed 's/^/        /'
    last=$(grep -v '^#' "$TMP/metrics" | grep 'last_available_backup_timestamp' | grep '^barman' | awk '{print $NF}' | head -1)
    [[ -n $last ]] && info "last available backup: $(date -u -d "@$(printf '%.0f' "$last")" '+%F %T UTC' 2>/dev/null)"
  else
    info "barman_cloud_* metrics not found; backup-related names:"
    grep -i 'backup\|recoverab' "$TMP/names" | sed 's/^/        /'
  fi
  info "other names useful for alerts:"
  grep -E 'collector_(up|nodes|sync|pg_wal|fencing|manual_switchover)|replication|streaming|archiver' "$TMP/names" \
    | sed 's/^/        /'
else
  fail "port-forward to $PRIMARY:9187 did not start"
fi

echo
echo "==> 4. Prometheus targets (expected down until M3)"
if forward monitoring svc/kube-prometheus-stack-prometheus 19090:9090; then
  curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' |
    jq -r '.data.activeTargets[] | select(.labels.namespace=="databases")
           | "        \(.labels.pod)  health=\(.health)  \(.lastError)"'
else
  info "port-forward to Prometheus did not start"
fi

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  M2 CloudNativePG passed (now run bash scripts/checks/test-gate.sh)" \
  || { echo "$(ts) RESULT  M2 CloudNativePG: $FAILS check(s) failed"; exit 1; }
