#!/usr/bin/env bash
# eso-consume-check.sh - proves that a change in OpenBao reaches the file inside the running pod hello-consumer.
#
# The refresh test only proves that a change in OpenBao reaches the
# Kubernetes Secret. This script follows the whole chain to a running
# workload: secret/demo/hello in OpenBao -> ExternalSecret hello (ESO, every
# 30 s) -> Secret eso-demo/hello-from-openbao -> file /etc/hello/message in
# the pod hello-consumer. The kubelet updates a mounted Secret file only
# after a delay (about 1 to 2 minutes), so the script waits up to 5 minutes
# for the file, and only then writes the old value back. It does not call
# eso-refresh-test.sh, because that script restores the value after about
# 50 s, which can be before the pod has seen the change.
#
# Each write logs in to OpenBao as eso-demo/demo-writer (not ESO, not root),
# writes, and revokes the token at once: a demo-writer token lives only 5
# minutes, shorter than the two waits together. Tokens go to the OpenBao pod
# through stdin and are never printed. If the script fails or is stopped
# (Ctrl+C), the cleanup writes hello-from-openbao back and revokes any token.
#
# Run it: bash scripts/external-secrets/eso-consume-check.sh | tee docs/evidence/05b-workload-consumes-secret.txt
#   (after git push of apps/external-secrets/deployment-hello-consumer.yaml; OpenBao unsealed)
# Changes the cluster: yes: asks Flux to apply Git now, changes the demo value
#   secret/demo/hello to hello-changed-<time> and writes hello-from-openbao
#   back at the end, also if the script fails. Creates two short-lived
#   demo-writer tokens and revokes each one right after its write.
#
# What it does:
#   1. Applies Git now and waits for the Deployment.
#        flux reconcile source git flux-system
#        flux reconcile kustomization apps-external-secrets
#        kubectl -n eso-demo rollout status deploy/hello-consumer --timeout=120s
#   2. Shows how the Secret is mounted and which user the pod runs as.
#        kubectl -n eso-demo get deploy hello-consumer -o jsonpath='{.spec.template.spec.volumes}'
#        kubectl -n eso-demo exec <pod> -- id
#   3. Reads the Secret and the file in the pod; both must be hello-from-openbao.
#        kubectl -n eso-demo exec <pod> -- cat /etc/hello/message
#   4. Writes hello-changed-<time> as demo-writer (fresh login, token revoked
#      right after the write).
#        kubectl -n eso-demo create token demo-writer --duration=10m
#        bao write -field=token auth/kubernetes/login role=demo-writer jwt=-
#        bao kv put -mount=secret demo/hello message=<value>
#        bao token revoke -self
#   5. Waits up to 5 minutes until the FILE IN THE POD shows the new value
#      (prints when the Secret had it and when the file had it).
#   6. Only then writes hello-from-openbao back (fresh login) and waits again.
#   7. Prints the pod log and checks it by counting: exactly 2 new lines since
#      step 3, and the hashes in the last 3 lines match original, changed,
#      restored. The pod logs only a hash, never the value.
#        printf '%s' <value> | sha256sum | cut -c1-12
#
# What you should see: PASS lines for the Deployment, the user id 65534, the
#   start value, "file in the pod: hello-changed-..." and "file in the pod:
#   hello-from-openbao" with the seconds each took, the pod log with three
#   "sha256" lines at the end, then "RESULT  workload check passed".
# If it fails: "file did not change after 300 s" prints what the Secret has
#   and what the file has. Secret still old: ESO did not sync, see
#   scripts/external-secrets/eso-debug.sh externalsecret hello. Secret new
#   but file old: the kubelet has not updated the mounted file yet. "no
#   active OpenBao pod": unseal first (scripts/after-restart/openbao-unseal.sh).
# Needs: flux, kubectl, jq. Tokens stay in variables and go through stdin.
set -euo pipefail
cd "$(dirname "$0")/../.."

NS=eso-demo
BAO_NS=openbao
FILE=/etc/hello/message
ORIGINAL=hello-from-openbao
WAIT_MAX=300
FAILS=0
CHANGED=no
RESTORED=no
WRITER_TOKEN=""

ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

secret_value() { kubectl -n "$NS" get secret hello-from-openbao -o jsonpath='{.data.message}' | base64 -d; }
# short_hash <value>: the same 12 characters the pod logs (sha256 of the file content)
short_hash()   { printf '%s' "$1" | sha256sum | cut -c1-12; }
file_value()   { kubectl -n "$NS" exec "$POD" -- cat "$FILE"; }

# revoke_token: revoke the current demo-writer token, if there is one
revoke_token() {
  [[ -n $WRITER_TOKEN ]] || return 0
  printf '%s\n' "$WRITER_TOKEN" |
    kubectl -n "$BAO_NS" exec -i "$BAO_POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao token revoke -self' >/dev/null || true
  WRITER_TOKEN=""
}

# write_value <value>: fresh demo-writer login, kv put secret/demo/hello message=<value>, revoke
write_value() {
  local value=$1 jwt rc
  jwt=$(kubectl -n "$NS" create token demo-writer --duration=10m)
  WRITER_TOKEN=$(printf '%s' "$jwt" |
    kubectl -n "$BAO_NS" exec -i "$BAO_POD" -- bao write -field=token auth/kubernetes/login role=demo-writer jwt=-)
  unset jwt
  printf '%s\n' "$WRITER_TOKEN" |
    kubectl -n "$BAO_NS" exec -i "$BAO_POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao kv put -mount=secret demo/hello "message=$1"' sh "$value" >/dev/null
  rc=$?
  revoke_token
  return $rc
}

# wait_file <value>: wait until the file in the pod has <value> (max WAIT_MAX s)
wait_file() {
  local want=$1 start=$SECONDS secret_at=""
  until [[ "$(file_value)" == "$want" ]]; do
    if [[ -z $secret_at && "$(secret_value)" == "$want" ]]; then secret_at=$(( SECONDS - start )); fi
    if (( SECONDS - start >= WAIT_MAX )); then
      fail "file did not change after $WAIT_MAX s (wanted: $want)"
      echo "        Kubernetes Secret has: $(secret_value)"
      echo "        file in the pod has:   $(file_value)"
      return 1
    fi
    sleep 5
  done
  [[ -n $secret_at ]] || secret_at=$(( SECONDS - start ))
  pass "file in the pod: $want (Secret after about $secret_at s, file after about $(( SECONDS - start )) s)"
}

# cleanup: on any exit, revoke a leftover token and put the original value back
cleanup() {
  local rc=$?
  set +e
  # After Ctrl+C, tee may be gone: ignore SIGPIPE so the restore still runs.
  trap '' PIPE
  revoke_token
  if [[ $CHANGED == yes && $RESTORED == no ]]; then
    info "cleanup: writing $ORIGINAL back to secret/demo/hello"
    if write_value "$ORIGINAL"; then
      info "cleanup: value restored; the Secret follows within 30 s, the file in the pod within about 2 min"
    else
      echo "$(ts) FAIL  cleanup: could not restore; run bash scripts/external-secrets/eso-refresh-test.sh"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> 1. Apply Git through Flux, wait for the Deployment"
flux reconcile source git flux-system
flux reconcile kustomization apps-external-secrets
kubectl -n "$NS" rollout status deploy/hello-consumer --timeout=120s
POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=hello-consumer \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
[[ -n $POD ]] && pass "Deployment hello-consumer ready, pod $POD" || { fail "no running hello-consumer pod"; exit 1; }
BAO_POD=$(kubectl -n "$BAO_NS" get pods -l app.kubernetes.io/name=openbao,component=server,openbao-active=true \
  -o jsonpath='{.items[0].metadata.name}')
[[ -n $BAO_POD ]] || { fail "no active OpenBao pod (unsealed?)"; exit 1; }

echo
echo "==> 2. How the Secret is mounted, which user the pod runs as"
kubectl -n "$NS" get deploy hello-consumer -o jsonpath='{.spec.template.spec.volumes}' | jq -c '.[]'
kubectl -n "$NS" get deploy hello-consumer -o jsonpath='{.spec.template.spec.containers[0].volumeMounts}' | jq -c '.[]'
ID=$(kubectl -n "$NS" exec "$POD" -- id)
echo "id in the pod: $ID"
[[ $ID == uid=65534* ]] && pass "pod runs as user 65534 (not root)" || fail "pod does not run as user 65534"

echo
echo "==> 3. Start: the Secret and the file in the pod"
S=$(secret_value); F=$(file_value)
echo "Kubernetes Secret: $S"
echo "file in the pod:   $F"
[[ $S == "$ORIGINAL" && $F == "$ORIGINAL" ]] && pass "both are $ORIGINAL" \
  || { fail "start value is not $ORIGINAL; run bash scripts/external-secrets/eso-refresh-test.sh first"; exit 1; }
LOG_BEFORE=$(kubectl -n "$NS" logs "$POD" | grep -c ' sha256 ' || true)
echo "pod log lines so far: $LOG_BEFORE"

NEW="hello-changed-$(date -u +%H%M%S)"
echo
echo "==> 4. Change secret/demo/hello in OpenBao to $NEW (as demo-writer)"
CHANGED=yes
write_value "$NEW"
pass "written; token revoked"

echo
echo "==> 5. Wait until the file in the pod shows $NEW (max $WAIT_MAX s)"
wait_file "$NEW"

echo
echo "==> 6. Write $ORIGINAL back (fresh login), wait again"
write_value "$ORIGINAL"
RESTORED=yes
pass "written; token revoked"
wait_file "$ORIGINAL"

echo
echo "==> 7. Pod log (one line per change, hash only, never the value)"
H_ORIG=$(short_hash "$ORIGINAL"); H_NEW=$(short_hash "$NEW")
echo "expected hashes: $ORIGINAL -> $H_ORIG, $NEW -> $H_NEW"
LOG=$(kubectl -n "$NS" logs "$POD")
echo "$LOG"
mapfile -t LINES < <(grep ' sha256 ' <<<"$LOG")
N=${#LINES[@]}
NEW_LINES=$(( N - LOG_BEFORE ))
(( NEW_LINES == 2 )) && pass "2 new log lines since step 3" || fail "$NEW_LINES new log lines since step 3 (expected 2)"
if (( N >= 3 )) && [[ ${LINES[N-3]} == *" sha256 $H_ORIG" && ${LINES[N-2]} == *" sha256 $H_NEW" && ${LINES[N-1]} == *" sha256 $H_ORIG" ]]; then
  pass "last 3 log lines have the hashes of $ORIGINAL, $NEW, $ORIGINAL"
else
  fail "last 3 log lines do not have the hashes of $ORIGINAL, $NEW, $ORIGINAL"
fi
grep -qF -e "$ORIGINAL" -e "$NEW" <<<"$LOG" && fail "the pod log contains a value" || pass "the pod log contains no value"

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  workload check passed" \
  || { echo "$(ts) RESULT  workload check: $FAILS check(s) failed"; exit 1; }
