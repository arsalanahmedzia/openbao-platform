#!/usr/bin/env bash
# Monitoring M3: after `git push`, applies the three new NetworkPolicies
# allow-prometheus-metrics (namespaces openbao, databases, external-secrets)
# and proves them. Existing policies are not changed.
#
# What it does:
#   1. Lets Flux apply the policies (they live in each namespace's own layer).
#        flux reconcile kustomization infra-controllers / apps-openbao / apps-database
#   2. Probes the metrics ports with temporary pods (kubectl run --rm, deleted
#      when done), nc -w 3 <pod IP> <port>:
#        open:    pod in monitoring labelled app.kubernetes.io/name=prometheus
#        blocked: unlabelled pod in monitoring, pod in default
#   3. Waits up to 3 min until Prometheus reports every target up (the real
#      proof, for OpenBao also that Prometheus accepts the TLS certificate).
#        curl http://127.0.0.1:19090/api/v1/targets (port-forward to Prometheus)
# Prints no secrets.
#   bash scripts/monitoring/monitoring-netpol-check.sh
set -uo pipefail

IMAGE=busybox:1.37.0
FAILS=0
ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

TMP=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

echo "==> 1. Flux"
flux reconcile source git flux-system
flux reconcile kustomization infra-controllers
flux reconcile kustomization apps-openbao
flux reconcile kustomization apps-database
for ns in openbao databases external-secrets; do
  kubectl -n "$ns" get networkpolicy allow-prometheus-metrics >/dev/null 2>&1 \
    && pass "NetworkPolicy $ns/allow-prometheus-metrics exists" || fail "NetworkPolicy $ns/allow-prometheus-metrics missing"
done

# probe <namespace> <labels or -> <host> <port> <expected: open|blocked>
probe() {
  local ns=$1 labels=$2 host=$3 port=$4 expected=$5 got args=() who=$1
  [[ "$labels" != - ]] && { args=(--labels="$labels"); who="$ns ($labels)"; }
  if kubectl -n "$ns" run "netpol-probe-$RANDOM" --image="$IMAGE" --restart=Never --rm -i --quiet "${args[@]}" \
       --command -- nc -w 3 "$host" "$port" </dev/null >/dev/null 2>&1; then got=open; else got=blocked; fi
  [[ "$got" == "$expected" ]] && pass "$who -> $host:$port expected $expected, got $got" \
    || fail "$who -> $host:$port expected $expected, got $got"
}

OPENBAO_IP=$(kubectl -n openbao get pod openbao-0 -o jsonpath='{.status.podIP}')
PRIMARY=$(kubectl -n databases get cluster pg-openbao -o jsonpath='{.status.currentPrimary}')
PG_IP=$(kubectl -n databases get pod "$PRIMARY" -o jsonpath='{.status.podIP}')
ESO_IP=$(kubectl -n external-secrets get pods -l app.kubernetes.io/name=external-secrets -o jsonpath='{.items[0].status.podIP}')
PROM=app.kubernetes.io/name=prometheus

echo
echo "==> 2. Connectivity (openbao-0 $OPENBAO_IP, $PRIMARY $PG_IP, ESO controller $ESO_IP)"
for target in "$OPENBAO_IP 9101" "$PG_IP 9187" "$ESO_IP 8080"; do
  set -- $target
  probe monitoring "$PROM" "$1" "$2" open
  probe monitoring - "$1" "$2" blocked
  probe default "$PROM" "$1" "$2" blocked
done

echo
echo "==> 3. Prometheus targets (waits up to 3 min for all up)"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:19090/-/ready && break; sleep 1; done
for _ in $(seq 1 18); do
  curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' > "$TMP/targets.json"
  jq -r '.data.activeTargets[] | select(.labels.namespace | IN("openbao","databases","external-secrets"))
         | .health' "$TMP/targets.json" > "$TMP/health"
  [[ -s $TMP/health ]] && ! grep -qv '^up$' "$TMP/health" && break
  sleep 10
done
jq -r '.data.activeTargets[] | "        \(.labels.job // "-")  \(.labels.pod // .labels.instance)  \(.scrapeUrl)  health=\(.health)  \(.lastError)"' \
  "$TMP/targets.json" | sort
for ns in openbao databases external-secrets; do
  total=$(jq --arg ns "$ns" '[.data.activeTargets[] | select(.labels.namespace==$ns)] | length' "$TMP/targets.json")
  up=$(jq --arg ns "$ns" '[.data.activeTargets[] | select(.labels.namespace==$ns and .health=="up")] | length' "$TMP/targets.json")
  (( total > 0 && up == total )) && pass "$ns: $up/$total targets up" || fail "$ns: $up/$total targets up"
done

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  M3 passed (now run bash scripts/checks/test-gate.sh)" \
  || { echo "$(ts) RESULT  M3: $FAILS check(s) failed"; exit 1; }
