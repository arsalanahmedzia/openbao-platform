#!/usr/bin/env bash
# Failure test F3: OpenBao is sealed while External Secrets runs.
#
# What it does:
#   1. Checks the start state: 3 OpenBao pods Ready, store and ExternalSecret
#      hello Ready; notes the value and resourceVersion of the Kubernetes Secret
#      hello-from-openbao and the ESO controller pod (name, restart count).
#   2. Asks y/N before breaking anything.
#   3. Breaks: deletes the 3 OpenBao pods. They are recreated by the
#      StatefulSet and come back SEALED (no root token needed).
#        kubectl -n openbao delete pod -l app.kubernetes.io/name=openbao,component=server
#   4. Watches F3_WATCH_ROUNDS x 15 s (default 8 = about 2 minutes): seal state
#      of the pods, store and ExternalSecret status, the Secret's value and
#      resourceVersion, the latest ESO errors.
#        kubectl get clustersecretstore openbao
#        kubectl -n eso-demo get externalsecret hello
#        kubectl -n external-secrets logs deploy/external-secrets
#   5. Unseals: bash scripts/openbao-unseal.sh (keys via stdin, never printed).
#   6. Watches the recovery (up to 15 min): time until the store and the
#      ExternalSecret are Ready again by themselves; checks the Secret kept its
#      value and the ESO controller was not restarted.
#   7. Cleanup (trap, also on failure or Ctrl+C): if any OpenBao pod is still
#      sealed, runs the unseal script.
#
# Output: PASS / FAIL / INFO lines with UTC times, also written to
# docs/evidence/07-f3-sealed.txt (F3_OUT to write elsewhere). No token or key
# is printed; only the demo value hello-from-openbao is shown.
#   bash scripts/failure-tests/failure-f3-sealed.sh
# Monitoring M6 (OpenBaoSealed must fire: sealed > 2 min after Prometheus
# notices, so about 4 min sealed):
#   F3_WATCH_ROUNDS=16 F3_OUT=docs/evidence/08-m6-f3-sealed.txt bash scripts/failure-tests/failure-f3-sealed.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=${F3_OUT:-docs/evidence/07-f3-sealed.txt}
ROUNDS=${F3_WATCH_ROUNDS:-8}
SELECTOR=app.kubernetes.io/name=openbao,component=server
FAILS=0

ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }
ready_of() { kubectl "$@" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].reason}'; }
store()  { ready_of get clustersecretstore openbao; }
extsec() { ready_of -n eso-demo get externalsecret hello; }
value()  { kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.data.message}' | base64 -d; }
rv()     { kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.metadata.resourceVersion}'; }
sealed_pods() { kubectl -n openbao get pods -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.openbao-sealed} {end}'; }
eso_pod() { kubectl -n external-secrets get pods -l app.kubernetes.io/name=external-secrets -o jsonpath='{.items[0].metadata.name} restarts={.items[0].status.containerStatuses[0].restartCount}'; }
eso_errors() {
  kubectl -n external-secrets logs deploy/external-secrets --since=60s 2>/dev/null |
    jq -rR 'fromjson? | select(.level=="error") | "\(.ts | floor | todate) \(.error // .msg)"' 2>/dev/null |
    cut -c1-170 | tail -2
}

echo "==> 1. Start state"
kubectl -n openbao get pods -l "$SELECTOR" -L openbao-active,openbao-sealed
echo "store: $(store) | ExternalSecret hello: $(extsec)"
[[ "$(store)" == True* && "$(extsec)" == True* ]] || { echo "store or ExternalSecret not Ready: run scripts/test-gate.sh first"; exit 1; }
VALUE0=$(value); RV0=$(rv); ESO0=$(eso_pod)
echo "Secret value: $VALUE0, resourceVersion $RV0; ESO controller: $ESO0"

read -r -p "This restarts all 3 OpenBao pods (they come back SEALED). Continue? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted, nothing changed"; exit 1; }

cleanup() {
  if [[ "$(sealed_pods)" == *=true* ]]; then
    info "cleanup: OpenBao pods still sealed, unsealing"
    bash scripts/openbao-unseal.sh >/dev/null 2>&1 || info "cleanup: unseal failed, run scripts/openbao-unseal.sh by hand"
  fi
}
trap cleanup EXIT

exec > >(tee "$OUT") 2>&1
echo "# F3: OpenBao sealed while ESO runs   $(date -u +%Y-%m-%d)"
echo "# Command: bash scripts/failure-tests/failure-f3-sealed.sh"
echo
info "start: store $(store); ExternalSecret $(extsec); Secret value $VALUE0 (resourceVersion $RV0); ESO controller $ESO0"

echo
echo "==> 3. Break: restart all OpenBao pods"
T0=$(date +%s); info "deleting the 3 OpenBao pods"
kubectl -n openbao delete pod -l "$SELECTOR" --wait=false
sleep 20
info "pods: $(sealed_pods)"
[[ "$(sealed_pods)" == *=true* ]] && pass "OpenBao pods are back SEALED" || info "no sealed label yet (pods may still be starting)"

echo
echo "==> 4. Watch while sealed ($ROUNDS x 15 s)"
for _ in $(seq 1 "$ROUNDS"); do
  info "t+$(( $(date +%s) - T0 ))s | store: $(store) | ExternalSecret: $(extsec) | Secret: $(value) rv=$(rv)"
  sleep 15
done
echo "--- latest ESO errors (last 60 s):"
eso_errors || true
[[ "$(value)" == "$VALUE0" ]] && pass "Secret hello-from-openbao kept its value while OpenBao was sealed" \
                              || fail "Secret value changed while sealed"

echo
echo "==> 5. Unseal"
T1=$(date +%s); info "running scripts/openbao-unseal.sh (keys via stdin, not shown)"
bash scripts/openbao-unseal.sh | grep -E 'unsealed|HA Mode'
info "unsealed after $(( $(date +%s) - T0 )) s sealed"

echo
echo "==> 6. Recovery without restarting ESO (up to 15 min)"
STORE_OK=""; ES_OK=""
while (( $(date +%s) - T1 < 900 )); do
  [[ -z "$STORE_OK" && "$(store)" == True* ]] && { STORE_OK=$(( $(date +%s) - T1 )); info "store Ready again after $STORE_OK s"; }
  [[ -z "$ES_OK" && "$(extsec)" == True* ]] && { ES_OK=$(( $(date +%s) - T1 )); info "ExternalSecret Ready again after $ES_OK s"; }
  [[ -n "$STORE_OK" && -n "$ES_OK" ]] && break
  (( ($(date +%s) - T1) % 60 == 0 )) && info "t+$(( $(date +%s) - T1 ))s after unseal | store: $(store) | ExternalSecret: $(extsec)"
  sleep 5
done
[[ -n "$STORE_OK" ]] && pass "store Valid/Ready again by itself ($STORE_OK s after unseal)" || fail "store not Ready 15 min after unseal"
[[ -n "$ES_OK" ]] && pass "ExternalSecret hello Ready again by itself ($ES_OK s after unseal)" || fail "ExternalSecret not Ready 15 min after unseal"
[[ "$(value)" == "$VALUE0" ]] && pass "Secret value still $VALUE0" || fail "Secret value is now $(value)"
info "Secret resourceVersion before $RV0, now $(rv)"
ESO1=$(eso_pod)
[[ "$ESO1" == "$ESO0" ]] && pass "ESO controller not restarted ($ESO1)" || fail "ESO controller changed: before $ESO0, now $ESO1"

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  F3 passed" || { echo "$(ts) RESULT  F3: $FAILS check(s) failed"; exit 1; }
