#!/usr/bin/env bash
# Failure test F5: the External Secrets controller restarts.
#
# What it does:
#   1. Checks the start state: ESO controller pod (name, IP), store and
#      ExternalSecret hello Ready; notes value and resourceVersion of the
#      Kubernetes Secret hello-from-openbao.
#   2. Asks y/N before breaking anything.
#   3. Breaks: deletes the ESO controller pod (only the controller: the webhook
#      and cert-controller have other names). The Deployment starts a new one.
#        kubectl -n external-secrets delete pod -l app.kubernetes.io/name=external-secrets
#   4. Waits for the new pod.
#        kubectl -n external-secrets rollout status deployment/external-secrets
#   5. Waits until the ExternalSecret was synced by the new pod (its
#      status.refreshTime is after the restart) and the store is Ready.
#   6. Proves the new login: the OpenBao audit log (stdout of the active pod)
#      shows auth/kubernetes/login responses for external-secrets coming from
#      the NEW pod's IP, with the token only as an HMAC hash. This script does
#      not log in to OpenBao itself, so every such login is ESO's.
#        kubectl -n openbao logs <active pod> | jq 'select(.request.path=="auth/kubernetes/login")'
#   7. Checks the Secret kept its value.
#   8. Cleanup (trap): nothing was changed except the deleted pod, which the
#      Deployment replaces; the trap only waits for the Deployment to be ready.
#
# Output: PASS / FAIL / INFO lines with UTC times, also written to
# docs/evidence/07-f5-eso-restart.txt. No token is printed; audit entries show
# HMAC hashes, cut to 24 characters. Only the demo value is shown.
#   bash scripts/failure-tests/failure-f5-eso-restart.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=docs/evidence/07-f5-eso-restart.txt
NS=external-secrets
SEL=app.kubernetes.io/name=external-secrets
FAILS=0

ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }
ready_of() { kubectl "$@" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].reason}'; }
value() { kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.data.message}' | base64 -d; }
rv()    { kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.metadata.resourceVersion}'; }
eso()   { kubectl -n "$NS" get pods -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP} {.status.phase}{"\n"}{end}'; }

echo "==> 1. Start state"
eso
STORE=$(ready_of get clustersecretstore openbao); ES=$(ready_of -n eso-demo get externalsecret hello)
echo "store: $STORE | ExternalSecret hello: $ES | Secret: $(value) rv=$(rv)"
[[ "$STORE" == True* && "$ES" == True* ]] || { echo "store or ExternalSecret not Ready: run scripts/test-gate.sh first"; exit 1; }
OLD_POD=$(eso | awk 'NR==1{print $1}'); OLD_IP=$(eso | awk 'NR==1{print $2}')
VALUE0=$(value); RV0=$(rv)

read -r -p "This deletes the ESO controller pod $OLD_POD. Continue? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted, nothing changed"; exit 1; }

cleanup() { kubectl -n "$NS" rollout status deployment/external-secrets --timeout=180s >/dev/null 2>&1 || info "cleanup: ESO Deployment not ready yet, check: kubectl -n $NS get pods"; }
trap cleanup EXIT

exec > >(tee "$OUT") 2>&1
echo "# F5: ESO restarts   $(date -u +%Y-%m-%d)"
echo "# Command: bash scripts/failure-tests/failure-f5-eso-restart.sh"
echo
info "start: ESO controller $OLD_POD ($OLD_IP); store $STORE; ExternalSecret $ES; Secret value $VALUE0 (resourceVersion $RV0)"

echo
echo "==> 3. Break: delete the ESO controller pod"
T0=$(date +%s); T0_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
info "deleting $OLD_POD"
kubectl -n "$NS" delete pod -l "$SEL" --wait=false

echo
echo "==> 4. New pod"
kubectl -n "$NS" rollout status deployment/external-secrets --timeout=180s
NEW_POD=$(kubectl -n "$NS" get pods -l "$SEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
NEW_IP=$(kubectl -n "$NS" get pod "$NEW_POD" -o jsonpath='{.status.podIP}')
[[ "$NEW_POD" != "$OLD_POD" ]] && pass "new ESO controller $NEW_POD ($NEW_IP) Ready after $(( $(date +%s) - T0 )) s" \
                                || fail "controller pod did not change ($NEW_POD)"
info "Secret while ESO restarted: $(value) rv=$(rv)"

echo
echo "==> 5. Sync by the new pod"
SYNCED=""
for _ in $(seq 36); do   # up to 3 minutes
  RT=$(kubectl -n eso-demo get externalsecret hello -o jsonpath='{.status.refreshTime}')
  [[ -n "$RT" && "$RT" > "$T0_ISO" && "$(ready_of -n eso-demo get externalsecret hello)" == True* ]] && { SYNCED=$(( $(date +%s) - T0 )); break; }
  sleep 5
done
[[ -n "$SYNCED" ]] && pass "ExternalSecret hello synced by the new pod (refreshTime $RT, $SYNCED s after the delete)" \
                   || fail "no new sync within 3 min (refreshTime ${RT:-none})"
STORE=$(ready_of get clustersecretstore openbao)
[[ "$STORE" == True* ]] && pass "store openbao $STORE" || fail "store openbao $STORE"

echo
echo "==> 6. New login in the OpenBao audit log (tokens shown only as hashes)"
BAO_POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')
sleep 5
LOGINS=$(kubectl -n openbao logs "$BAO_POD" --since="$(( $(date +%s) - T0 + 10 ))s" |
  jq -rR --arg ip "$NEW_IP" 'fromjson? | select(.type=="response" and .request.path=="auth/kubernetes/login")
    | "\(.time) \(.auth.display_name // "-") from \(.request.remote_address) policies=\(.auth.policies // [] | join(",")) token=\((.auth.client_token // "")[0:24])..."')
if [[ -n "$LOGINS" ]]; then
  echo "$LOGINS" | head -5
  info "logins since the restart: $(wc -l <<<"$LOGINS"), from the new pod's IP $NEW_IP: $(grep -c "from $NEW_IP" <<<"$LOGINS" || true)"
  grep -q "from $NEW_IP" <<<"$LOGINS" && pass "the new ESO pod logged in to OpenBao with a new token (audit log, $BAO_POD)" \
                                      || fail "no login from the new pod's IP $NEW_IP in the audit log of $BAO_POD"
else
  fail "no auth/kubernetes/login in the audit log of $BAO_POD since the restart"
fi

echo
echo "==> 7. Secret"
[[ "$(value)" == "$VALUE0" ]] && pass "Secret hello-from-openbao still $VALUE0" || fail "Secret value is now $(value)"
info "Secret resourceVersion before $RV0, now $(rv)"

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  F5 passed" || { echo "$(ts) RESULT  F5: $FAILS check(s) failed"; exit 1; }
