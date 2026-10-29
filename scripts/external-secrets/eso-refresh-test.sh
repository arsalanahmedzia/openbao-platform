#!/usr/bin/env bash
# External Secrets stage, step 6: proves the refresh of the ExternalSecret.
# Logs in to OpenBao as eso-demo/demo-writer (role demo-writer, policy
# demo-write; not ESO, not root), changes secret/demo/hello, waits until the
# Kubernetes Secret eso-demo/hello-from-openbao shows the new value (refresh
# interval 30 s), then restores hello-from-openbao the same way.
# Demo values only; tokens stay in variables and go to the pod via stdin.
#   bash scripts/external-secrets/eso-refresh-test.sh
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
