#!/usr/bin/env bash
# Monitoring M2, External Secrets: after `git push`, lets Flux apply the
# PodMonitor external-secrets and checks the controller's metrics. Read-only
# apart from the Flux reconcile; no pod restarts. Prints no secrets (the
# metrics only carry object names and conditions, no values).
#
# What it does:
#   1. Lets Flux apply the PodMonitor.
#        flux reconcile kustomization apps-monitoring
#   2. Reads the controller's metrics through a port-forward (enters the pod
#      directly, so no NetworkPolicy is involved):
#        kubectl -n external-secrets port-forward deploy/external-secrets 18080:8080
#        curl http://127.0.0.1:18080/metrics
#   3. Shows the status metrics needed for the alerts in M4 (ExternalSecret,
#      PushSecret and ClusterSecretStore conditions).
#   4. Shows the Prometheus target state (down until M3 adds the
#      NetworkPolicy that lets Prometheus reach port 8080).
#   bash scripts/monitoring-eso-metrics.sh
set -uo pipefail

NS=external-secrets
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
kubectl -n monitoring get podmonitor external-secrets >/dev/null 2>&1 && pass "PodMonitor monitoring/external-secrets exists" \
  || fail "PodMonitor monitoring/external-secrets missing"

echo
echo "==> 2. Metrics from the ESO controller (port-forward 18080 -> 8080)"
if forward "$NS" deploy/external-secrets 18080:8080; then
  code=$(curl -s -o "$TMP/metrics" -w '%{http_code}' http://127.0.0.1:18080/metrics)
  info "GET :8080/metrics -> HTTP $code, $(grep -vc '^#' "$TMP/metrics") sample lines"
  [[ $code == 200 ]] && pass "controller metrics answer" || fail "controller metrics HTTP $code"
  grep -v '^#' "$TMP/metrics" | sed 's/[{ ].*//' | sort -u > "$TMP/names"
  info "distinct metric names: $(wc -l < "$TMP/names")"

  echo
  echo "==> 3. Status metrics for the alerts (M4)"
  for m in externalsecret_status_condition clustersecretstore_status_condition pushsecret_status_condition; do
    if grep -qx "$m" "$TMP/names"; then
      pass "$m present:"
      grep "^$m{" "$TMP/metrics" | sed 's/^/        /'
    else
      fail "$m missing"
    fi
  done
  info "other ESO names:"
  grep -E '^(externalsecret|pushsecret|clustersecretstore|secretstore|clusterexternalsecret)_' "$TMP/names" \
    | grep -v '_status_condition$' | sed 's/^/        /'
else
  fail "port-forward to deploy/external-secrets:8080 did not start"
fi

echo
echo "==> 4. Prometheus targets (expected down until M3)"
if forward monitoring svc/kube-prometheus-stack-prometheus 19090:9090; then
  curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' |
    jq -r '.data.activeTargets[] | select(.labels.namespace=="external-secrets")
           | "        \(.labels.pod)  health=\(.health)  \(.lastError)"'
else
  info "port-forward to Prometheus did not start"
fi

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  M2 External Secrets passed (now run bash scripts/test-gate.sh)" \
  || { echo "$(ts) RESULT  M2 External Secrets: $FAILS check(s) failed"; exit 1; }
