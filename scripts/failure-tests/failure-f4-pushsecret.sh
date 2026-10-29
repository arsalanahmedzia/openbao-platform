#!/usr/bin/env bash
# Failure test F4: the PushSecret is deleted.
#
# What it does:
#   1. Checks the start state: PushSecret push-demo Ready, and the pushed value
#      readable in OpenBao as the ESO login (Kubernetes auth, role
#      external-secrets; same pattern as scripts/external-secrets/eso-push-check.sh).
#        bao kv get -mount=secret -field=message pushed/push-demo
#   2. Asks y/N before changing anything.
#   3. Pauses Flux for the layer apps-external-secrets, so Flux does not
#      recreate the PushSecret during the test (makes the order fixed).
#        flux suspend kustomization apps-external-secrets
#   4. Breaks: deletes the PushSecret. With deletionPolicy Delete, ESO first
#      deletes secret/pushed/push-demo in OpenBao (a finalizer holds the object
#      until then), then the object is gone.
#        kubectl -n eso-demo delete pushsecret push-demo
#   5. Shows the value is gone from OpenBao (data and metadata).
#   6. Resumes Flux: it recreates the PushSecret from Git, ESO pushes again.
#        flux resume kustomization apps-external-secrets
#   7. Shows the value is back in OpenBao and the PushSecret is Synced.
#   8. Cleanup (trap, also on failure or Ctrl+C): resumes Flux if it is still
#      suspended, revokes the ESO token.
#
# Output: PASS / FAIL / INFO lines with UTC times, also written to
# docs/evidence/07-f4-pushsecret.txt. Tokens stay in variables and go to the
# pod via stdin; only the demo value pushed-from-kubernetes is shown.
#   bash scripts/failure-tests/failure-f4-pushsecret.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=docs/evidence/07-f4-pushsecret.txt
KS=apps-external-secrets
FAILS=0

ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }
suspended() { kubectl -n flux-system get kustomization "$KS" -o jsonpath='{.spec.suspend}'; }
push_ready() { kubectl -n eso-demo get pushsecret push-demo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "absent"; }

BAO_POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')
[[ -n "$BAO_POD" ]] || { echo "no active OpenBao pod: unseal first"; exit 1; }
# with_token <bao args...>: bao in the active pod, ESO token via stdin
with_token() {
  printf '%s\n' "$ESO_TOKEN" |
    kubectl -n openbao exec -i "$BAO_POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}
# pushed: the value in OpenBao, "absent" if not found, "error: ..." otherwise
pushed() {
  local out
  if out=$(with_token kv get -mount=secret -field=message pushed/push-demo 2>&1); then echo "$out"
  elif grep -q 'No value found' <<<"$out"; then echo absent
  else echo "error: $(tail -1 <<<"$out")"; fi
}

JWT=$(kubectl -n external-secrets create token external-secrets --duration=15m)
ESO_TOKEN=$(printf '%s' "$JWT" |
  kubectl -n openbao exec -i "$BAO_POD" -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-)
unset JWT

cleanup() {
  if [[ "$(suspended)" == true ]]; then
    info "cleanup: resuming Flux kustomization $KS"
    flux resume kustomization "$KS" >/dev/null 2>&1 || info "cleanup: resume failed, run: flux resume kustomization $KS"
  fi
  with_token token revoke -self >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> 1. Start state"
echo "PushSecret push-demo: $(push_ready); value in OpenBao (as ESO login): $(pushed); Flux $KS suspended: $(suspended)"
[[ "$(push_ready)" == True* && "$(pushed)" == pushed-from-kubernetes ]] || { echo "start state not as expected: run scripts/checks/test-gate.sh first"; exit 1; }

read -r -p "This pauses Flux for $KS and deletes the PushSecret push-demo. Continue? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted, nothing changed"; exit 1; }

exec > >(tee "$OUT") 2>&1
echo "# F4: the PushSecret is deleted   $(date -u +%Y-%m-%d)"
echo "# Command: bash scripts/failure-tests/failure-f4-pushsecret.sh"
echo
info "start: PushSecret $(push_ready); secret/pushed/push-demo = $(pushed) (read as the ESO login)"

echo
echo "==> 3. Pause Flux for $KS"
flux suspend kustomization "$KS"
[[ "$(suspended)" == true ]] && pass "Flux $KS suspended" || fail "Flux $KS not suspended"

echo
echo "==> 4. Break: delete the PushSecret"
T0=$(date +%s); info "deleting pushsecret eso-demo/push-demo (waits for ESO's finalizer)"
kubectl -n eso-demo delete pushsecret push-demo --timeout=120s
info "PushSecret object gone after $(( $(date +%s) - T0 )) s"

echo
echo "==> 5. Value in OpenBao"
for _ in $(seq 12); do [[ "$(pushed)" == absent ]] && break; sleep 5; done
NOW=$(pushed)
[[ "$NOW" == absent ]] && pass "secret/pushed/push-demo deleted in OpenBao (deletionPolicy Delete), $(( $(date +%s) - T0 )) s after the delete" \
                       || fail "secret/pushed/push-demo still there or error: $NOW"
META=$(with_token kv metadata get -mount=secret pushed/push-demo 2>&1 || true)
grep -q 'No value found' <<<"$META" && pass "metadata deleted too (all versions gone)" || info "metadata: $(tail -1 <<<"$META")"
info "while paused: PushSecret $(push_ready); Kubernetes source Secret push-demo still there: $(kubectl -n eso-demo get secret push-demo -o name 2>/dev/null || echo no)"

echo
echo "==> 6. Resume Flux"
T1=$(date +%s); info "resuming Flux $KS (it reconciles right away)"
flux resume kustomization "$KS"
[[ "$(suspended)" != true ]] && pass "Flux $KS resumed" || fail "Flux $KS still suspended"

echo
echo "==> 7. Restore"
BACK=""
for _ in $(seq 36); do   # up to 3 minutes
  [[ "$(push_ready)" == True* && "$(pushed)" == pushed-from-kubernetes ]] && { BACK=$(( $(date +%s) - T1 )); break; }
  sleep 5
done
[[ -n "$BACK" ]] && pass "Flux recreated the PushSecret and the value is back in OpenBao after $BACK s" \
                 || fail "after 3 min: PushSecret $(push_ready), value $(pushed)"
info "end: PushSecret $(push_ready); secret/pushed/push-demo = $(pushed)"
with_token kv metadata get -mount=secret pushed/push-demo 2>/dev/null | grep -E '^(created_time|current_version|custom_metadata) ' || true

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  F4 passed" || { echo "$(ts) RESULT  F4: $FAILS check(s) failed"; exit 1; }
