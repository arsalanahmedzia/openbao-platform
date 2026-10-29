#!/usr/bin/env bash
# failure-f2-postgres.sh - failure test F2: deletes the PostgreSQL primary and measures the failover and the write outage.
#
# This test answers: what happens to OpenBao when the PostgreSQL primary
# (the copy that accepts writes) dies? It deletes the primary pod.
# CloudNativePG then promotes one of the replicas to be the new primary and
# recreates the deleted pod as a replica.
#
# While that happens, a background check writes a small test value into
# OpenBao every 2 seconds, logged in as External Secrets. A write must reach
# PostgreSQL, so the log shows exactly how long OpenBao could not write. The
# script measures the time until a new primary exists and until all 3
# instances are ready again. At the end it deletes the test value and the
# token. The output also goes to docs/evidence/07-f2-postgres.txt.
#
# Run it: bash scripts/failure-tests/failure-f2-postgres.sh (run test-gate.sh before and after)
# Changes the cluster: breaks something on purpose, asks first: deletes the primary pod;
#   CloudNativePG recreates it. Writes and deletes secret/pushed/f2-probe.
#
# What it does:
#   1. Checks the start state: cluster pg-openbao healthy with 3 ready
#      instances; notes the current primary and the active OpenBao pod.
#        kubectl -n databases get cluster pg-openbao -o jsonpath=...
#   2. Asks y/N before breaking anything.
#   3. Logs in to OpenBao as the ESO service account (Kubernetes auth, role
#      external-secrets; same pattern as scripts/external-secrets/eso-push-check.sh) and starts a
#      background probe: every 2 s it WRITES secret/pushed/f2-probe (allowed by
#      eso-write). A write must reach PostgreSQL; reads could come from
#      OpenBao's cache. Each attempt is logged as ok/fail with the time.
#        kubectl -n external-secrets create token external-secrets
#        bao write auth/kubernetes/login role=external-secrets jwt=-
#        bao kv put -mount=secret pushed/f2-probe n=<counter>
#   4. Breaks: deletes the primary pod (CloudNativePG starts a failover).
#        kubectl -n databases delete pod <primary> --wait=false
#   5. Watches: time until another instance is primary, time until the
#      cluster is healthy with 3 ready instances again, the old primary back
#      as a replica.
#        kubectl -n databases get cluster pg-openbao -o jsonpath='{.status.currentPrimary}'
#   6. Checks OpenBao: write outage from the probe, and a read of
#      secret/demo/hello as the ESO login; prints `kubectl cnpg status`.
#   7. Cleanup (trap, also on failure): stops the probe, deletes
#      secret/pushed/f2-probe, revokes the ESO token. The deleted pod is
#      recreated by CloudNativePG itself; nothing else was changed.
#
# Output: PASS / FAIL / INFO lines with UTC times, also written to
# docs/evidence/07-f2-postgres.txt. Tokens stay in variables and go to the
# pod via stdin; only the demo value hello-from-openbao is shown.
#
# What you should see: the probe log (ok/fail per write), the time until a new primary and
#   until 3 ready instances, then "RESULT F2 passed".
# If it fails: the cluster does not get healthy again: kubectl cnpg status pg-openbao
#   -n databases; a deleted primary waits up to 180 s for open connections (risk R28).
# Needs: kubectl with the cnpg plugin, jq.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=docs/evidence/07-f2-postgres.txt
DB_NS=databases
BAO_NS=openbao
CLUSTER=pg-openbao
PROBE_LOG=$(mktemp)
FAILS=0

ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }
primary() { kubectl -n "$DB_NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}'; }
ready()   { kubectl -n "$DB_NS" get cluster "$CLUSTER" -o jsonpath='{.status.readyInstances}'; }
phase()   { kubectl -n "$DB_NS" get cluster "$CLUSTER" -o jsonpath='{.status.phase}'; }

echo "==> 1. Start state"
PRIMARY=$(primary)
PRIMARY_NODE=$(kubectl -n "$DB_NS" get pod "$PRIMARY" -o jsonpath='{.spec.nodeName}')
BAO_POD=$(kubectl -n "$BAO_NS" get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')
echo "primary: $PRIMARY on $PRIMARY_NODE, ready instances: $(ready), phase: $(phase)"
echo "active OpenBao pod: $BAO_POD"
[[ "$(ready)" == 3 && "$(phase)" == *healthy* ]] || { echo "cluster not healthy with 3 instances: run scripts/checks/test-gate.sh first"; exit 1; }
[[ -n "$BAO_POD" ]] || { echo "no active OpenBao pod: unseal first"; exit 1; }

read -r -p "This deletes the PostgreSQL PRIMARY pod $PRIMARY. Continue? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted, nothing changed"; exit 1; }

exec > >(tee "$OUT") 2>&1
echo "# F2: the PostgreSQL primary dies   $(date -u +%Y-%m-%d)"
echo "# Command: bash scripts/failure-tests/failure-f2-postgres.sh"
echo
info "start: primary $PRIMARY on $PRIMARY_NODE, 3 ready instances; active OpenBao pod $BAO_POD"

# with_token <bao args...>: runs bao in the active OpenBao pod, token via stdin
with_token() {
  printf '%s\n' "$ESO_TOKEN" |
    kubectl -n "$BAO_NS" exec -i "$BAO_POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}

PROBE_PID=""
cleanup() {
  [[ -n "$PROBE_PID" ]] && kill "$PROBE_PID" 2>/dev/null || true
  if [[ -n "${ESO_TOKEN:-}" ]]; then
    with_token kv metadata delete -mount=secret pushed/f2-probe >/dev/null 2>&1 || true
    with_token token revoke -self >/dev/null 2>&1 || true
  fi
  rm -f "$PROBE_LOG"
  info "cleanup done: probe stopped, secret/pushed/f2-probe deleted, ESO token revoked"
}
trap cleanup EXIT

echo
echo "==> 3. ESO login and write probe (every 2 s)"
JWT=$(kubectl -n external-secrets create token external-secrets --duration=15m)
ESO_TOKEN=$(printf '%s' "$JWT" |
  kubectl -n "$BAO_NS" exec -i "$BAO_POD" -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-)
unset JWT
info "logged in as external-secrets (token not shown)"
(
  n=0
  while true; do
    n=$((n + 1))
    if printf '%s\n' "$ESO_TOKEN" | timeout 5 kubectl -n "$BAO_NS" exec -i "$BAO_POD" -- \
         sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao kv put -mount=secret pushed/f2-probe n="$1"' sh "$n" >/dev/null 2>&1
    then echo "$(date -u +%T) $(date +%s) ok" >> "$PROBE_LOG"
    else echo "$(date -u +%T) $(date +%s) fail" >> "$PROBE_LOG"; fi
    sleep 2
  done
) &
PROBE_PID=$!
sleep 6
grep -q ' ok$' "$PROBE_LOG" && pass "write probe works before the break" || fail "write probe fails before the break"

echo
echo "==> 4. Break: delete the primary pod $PRIMARY"
T0=$(date +%s); info "deleting pod $PRIMARY"
kubectl -n "$DB_NS" delete pod "$PRIMARY" --wait=false

echo
echo "==> 5. Watch the failover"
NEW=""
info "waiting for a new primary (up to 300 s; a deleted primary may first wait up to 180 s for open connections)"
while (( $(date +%s) - T0 < 300 )); do
  NEW=$(primary)
  [[ -n "$NEW" && "$NEW" != "$PRIMARY" ]] && break
  (( ($(date +%s) - T0) % 30 == 0 )) && info "still $PRIMARY after $(( $(date +%s) - T0 )) s, phase: $(phase)"
  sleep 1
done
if [[ -n "$NEW" && "$NEW" != "$PRIMARY" ]]; then
  pass "new primary $NEW after $(( $(date +%s) - T0 )) s"
  info "promoted at $(kubectl -n "$DB_NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimaryTimestamp}')"
else
  fail "no new primary after 300 s (still $NEW)"
fi

HEALTHY=no
while (( $(date +%s) - T0 < 600 )); do
  [[ "$(ready)" == 3 && "$(phase)" == *healthy* ]] && { HEALTHY=yes; break; }
  sleep 5
done
[[ "$HEALTHY" == yes ]] && pass "cluster healthy with 3 ready instances after $(( $(date +%s) - T0 )) s" \
                        || fail "cluster not healthy with 3 instances after 600 s (phase: $(phase))"
kubectl -n "$DB_NS" get pods -o wide -L cnpg.io/instanceRole
ROLE=$(kubectl -n "$DB_NS" get pod "$PRIMARY" -o jsonpath='{.metadata.labels.cnpg\.io/instanceRole}' 2>/dev/null || true)
[[ "$ROLE" == replica ]] && pass "old primary $PRIMARY is back as a replica" || fail "old primary $PRIMARY role: ${ROLE:-missing}"

echo
echo "==> 6. OpenBao"
sleep 4
kill "$PROBE_PID" 2>/dev/null || true; PROBE_PID=""
FAILED=$(grep -c ' fail$' "$PROBE_LOG" || true)
info "write probe: $(grep -c ' ok$' "$PROBE_LOG" || true) ok, $FAILED failed (one attempt every ~2 s)"
if (( FAILED > 0 )); then
  FIRST_FAIL=$(awk '$3=="fail"{print $1" "$2; exit}' "$PROBE_LOG")
  LAST_FAIL=$(awk '$3=="fail"{l=$1" "$2} END{print l}' "$PROBE_LOG")
  info "first failed write ${FIRST_FAIL% *} ($(( ${FIRST_FAIL#* } - T0 )) s after delete), last failed write ${LAST_FAIL% *} ($(( ${LAST_FAIL#* } - T0 )) s after delete)"
else
  info "no write failed: any outage was shorter than the probe interval"
fi
[[ "$(tail -1 "$PROBE_LOG" | awk '{print $3}')" == ok ]] && pass "OpenBao writes work again" || fail "last OpenBao write failed"
VALUE=$(with_token kv get -mount=secret -field=message demo/hello 2>/dev/null || true)
[[ "$VALUE" == hello-from-openbao ]] && pass "read secret/demo/hello as the ESO login: $VALUE" || fail "read secret/demo/hello as the ESO login failed"
echo
timeout 30 kubectl cnpg status "$CLUSTER" -n "$DB_NS" |
  sed -n -e '/^Status:/p' -e '/^Instances:/p' -e '/^Ready instances:/p' -e '/^Current Write LSN/p' -e '/Instances status/,/^$/p' || true

echo
info "replication is asynchronous: a transaction confirmed by the old primary in its last moment may not have reached a replica, so a small data-loss window is possible in theory (ADR 0003)"
echo
(( FAILS == 0 )) && echo "$(ts) RESULT  F2 passed" || { echo "$(ts) RESULT  F2: $FAILS check(s) failed"; exit 1; }
