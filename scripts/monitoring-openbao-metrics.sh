#!/usr/bin/env bash
# Monitoring M2, OpenBao: after `git push`, rolls out the new OpenBao config
# (metrics listener on port 9101) and checks the metrics. Prints no keys or
# tokens; the metrics need no token.
#
# What it does:
#   1. Rolls out the config change: Flux reconcile, restart the outdated pods
#      one at a time (standbys first), unseal each new pod.
#        bash scripts/openbao-tls-rollout.sh
#   2. Lets Flux apply the PodMonitor.
#        flux reconcile kustomization apps-monitoring
#   3. Reads the metrics of one pod through a port-forward (enters the pod
#      directly, so no NetworkPolicy is involved):
#        kubectl -n openbao port-forward pod/openbao-0 19101:9101
#        curl http://127.0.0.1:19101/v1/sys/metrics?format=prometheus
#   4. Checks the metrics listener serves nothing else (/v1/sys/health) and
#      that /v1/sys/metrics through Traefik is not answered with metrics.
#   5. Shows the Prometheus target state (down until M3 adds the
#      NetworkPolicy that lets Prometheus reach port 9101).
#   bash scripts/monitoring-openbao-metrics.sh
set -uo pipefail
cd "$(dirname "$0")/.."

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
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

echo "==> 1. Rollout (pods restart sealed and are unsealed one by one)"
bash scripts/openbao-tls-rollout.sh || fail "rollout script failed"
kubectl -n "$NS" wait pod -l "$SELECTOR" --for=condition=Ready --timeout=120s >/dev/null 2>&1 \
  && pass "3 OpenBao pods Ready (unsealed)" || fail "not all OpenBao pods Ready"
ports=$(kubectl -n "$NS" get pods -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.containers[0].ports[?(@.name=="metrics")].containerPort}{" "}{end}')
info "metrics container port per pod: $ports"
[[ $(grep -o '=9101' <<<"$ports" | wc -l) -eq 3 ]] && pass "all 3 pods declare port 9101 (metrics)" \
  || fail "not all pods declare port 9101"

echo
echo "==> 2. PodMonitor"
flux reconcile kustomization apps-monitoring
kubectl -n monitoring get podmonitor openbao >/dev/null 2>&1 && pass "PodMonitor monitoring/openbao exists" \
  || fail "PodMonitor monitoring/openbao missing"

echo
echo "==> 3. Metrics from openbao-0 (port-forward 19101 -> 9101)"
if forward "$NS" pod/openbao-0 19101:9101; then
  code=$(curl -s -o "$TMP/metrics" -w '%{http_code}' 'http://127.0.0.1:19101/v1/sys/metrics?format=prometheus')
  info "GET :9101/v1/sys/metrics?format=prometheus -> HTTP $code, $(grep -vc '^#' "$TMP/metrics") sample lines"
  [[ $code == 200 ]] && pass "metrics listener answers without a token" || fail "metrics listener HTTP $code"
  if grep -q '^vault_core_unsealed' "$TMP/metrics"; then
    pass "vault_core_unsealed present: $(grep '^vault_core_unsealed' "$TMP/metrics")"
  else
    info "vault_core_unsealed not in the output (OpenBaoSealed alert will use pod readiness)"
  fi
  info "metric names (first 25, for M4):"
  grep -v '^#' "$TMP/metrics" | sed 's/[{ ].*//' | sort -u | head -25 | sed 's/^/        /'
  grep -v '^#' "$TMP/metrics" | sed 's/[{ ].*//' | sort -u > "$TMP/names"
  info "distinct metric names: $(wc -l < "$TMP/names")"

  echo
  echo "==> 4. The metrics listener serves only metrics"
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:19101/v1/sys/health)
  [[ $code != 200 ]] && pass "GET :9101/v1/sys/health -> HTTP $code (not served)" \
    || fail "GET :9101/v1/sys/health -> HTTP 200 (metrics_only not active)"
else
  fail "port-forward to openbao-0:9101 did not start"
fi
kubectl -n "$NS" get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"
code=$(curl -s -o "$TMP/traefik" -w '%{http_code}' --resolve openbao.demo.local:443:127.0.0.1 \
       --cacert "$TMP/ca.crt" 'https://openbao.demo.local/v1/sys/metrics?format=prometheus')
if [[ $code != 200 ]] && ! grep -q '^vault_' "$TMP/traefik"; then
  pass "GET https://openbao.demo.local/v1/sys/metrics -> HTTP $code, no metrics through Traefik"
else
  fail "metrics reachable through Traefik (HTTP $code)"
fi

echo
echo "==> 5. Prometheus target (expected down until M3)"
if forward monitoring svc/kube-prometheus-stack-prometheus 19090:9090; then
  curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' |
    jq -r '.data.activeTargets[] | select(.labels.namespace=="openbao")
           | "        \(.labels.pod)  health=\(.health)  \(.lastError)"'
else
  info "port-forward to Prometheus did not start"
fi

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  M2 OpenBao passed (now run bash scripts/test-gate.sh)" \
  || { echo "$(ts) RESULT  M2 OpenBao: $FAILS check(s) failed"; exit 1; }
