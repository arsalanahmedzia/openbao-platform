#!/usr/bin/env bash
# eso-refresh-test.sh - proves that a change in OpenBao reaches the Kubernetes Secret.
#
# In plain words:
#   Pull is only useful if a change in OpenBao reaches Kubernetes by itself.
#   This script proves that. It logs in to OpenBao as a separate demo writer
#   (not as ESO and not as root, so ESO's own rights stay read-only on that
#   path), writes a new value hello-changed-<time> into secret/demo/hello, and
#   waits until the Kubernetes Secret shows the new value. ESO checks every 30
#   s, so this takes up to about half a minute.
#
#   Then it writes hello-from-openbao back and waits again, so the demo ends
#   the way it started. Tokens go to the pod through stdin and are never
#   printed.
#
# Run it: bash scripts/external-secrets/eso-refresh-test.sh (any time; eso-evidence.sh and netpol-test-eso-demo.sh run it)
# Changes the cluster: yes: changes the demo value secret/demo/hello and restores
#   it to hello-from-openbao at the end.
#
# What it does:
#   1. Logs in to OpenBao as eso-demo/demo-writer (role demo-writer, policy
#      demo-write; not ESO, not root).
#        kubectl -n eso-demo create token demo-writer --duration=10m
#        bao write -field=token auth/kubernetes/login role=demo-writer jwt=-
#   2. Writes a new value hello-changed-<time>.
#        bao kv put -mount=secret demo/hello message=<new value>
#   3. Waits up to 90 s until the Secret eso-demo/hello-from-openbao shows it
#      (refresh interval 30 s).
#   4. Writes hello-from-openbao back, waits again, revokes the token.
#
# What you should see: "Kubernetes Secret now: hello-changed-... (after about N s)",
#   then "Kubernetes Secret now: hello-from-openbao".
# If it fails: "not synced after 90 s" shows the value it still has; see
#   scripts/external-secrets/eso-debug.sh externalsecret hello. "no active
#   OpenBao pod": unseal first.
# Needs: kubectl. Tokens stay in variables and go to the pod through stdin.
set -euo pipefail

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
POD=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "no active OpenBao pod (unsealed?)"; exit 1; }

k8s_value() { kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.data.message}' | base64 -d; }

# write_as_demo_writer <value>: kv put secret/demo/hello message=<value>
write_as_demo_writer() {
  printf '%s\n' "$WRITER_TOKEN" |
    kubectl -n "$NS" exec -i "$POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao kv put -mount=secret demo/hello "message=$1"' sh "$1" >/dev/null
}

# wait_for <value>: poll the Kubernetes Secret until it has <value> (max 90 s)
wait_for() {
  local start=$SECONDS
  until [[ "$(k8s_value)" == "$1" ]]; do
    (( SECONDS - start < 90 )) || { echo "not synced after 90 s (still: $(k8s_value))"; exit 1; }
    sleep 2
  done
  echo "Kubernetes Secret now: $(k8s_value)   (after about $(( SECONDS - start )) s)"
}

echo "==> Before: Kubernetes Secret eso-demo/hello-from-openbao = $(k8s_value)"

echo
echo "==> Login to OpenBao as eso-demo/demo-writer (Kubernetes auth, role demo-writer)"
JWT=$(kubectl -n eso-demo create token demo-writer --duration=10m)
WRITER_TOKEN=$(printf '%s' "$JWT" |
  kubectl -n "$NS" exec -i "$POD" -- bao write -field=token auth/kubernetes/login role=demo-writer jwt=-)
unset JWT
echo "login ok"

NEW="hello-changed-$(date -u +%H%M%S)"
echo
echo "==> Change secret/demo/hello in OpenBao to: $NEW"
write_as_demo_writer "$NEW"
echo "==> Waiting for ESO to refresh (interval 30 s)"
wait_for "$NEW"

echo
echo "==> Restore secret/demo/hello to: hello-from-openbao"
write_as_demo_writer hello-from-openbao
wait_for hello-from-openbao

printf '%s\n' "$WRITER_TOKEN" |
  kubectl -n "$NS" exec -i "$POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao token revoke -self' >/dev/null
unset WRITER_TOKEN
echo
kubectl -n eso-demo get externalsecret hello
