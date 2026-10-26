#!/usr/bin/env bash
# External Secrets stage, step 3: applies the policy files in openbao/policies/
# (eso-read, eso-write, demo-write) and the role demo-writer, then proves the
# new PushSecret rights AS the ESO login: write and delete the managed-by
# marker on secret/metadata/pushed/policy-check.
# Uses the root token (from OPENBAO_ROOT_TOKEN or ~/openbao-init.json) through
# stdin only, never printed. openbao-configure.sh does the same from scratch.
#   bash scripts/openbao-policy-update.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
INIT_FILE="$HOME/openbao-init.json"

if [[ -n "${OPENBAO_ROOT_TOKEN:-}" ]]; then
  ROOT_TOKEN=$OPENBAO_ROOT_TOKEN
elif [[ -r "$INIT_FILE" ]]; then
  ROOT_TOKEN=$(jq -r .root_token "$INIT_FILE")
else
  echo "no root token: set OPENBAO_ROOT_TOKEN or provide $INIT_FILE"; exit 1
fi
POD=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "no active OpenBao pod (unsealed?)"; exit 1; }

# bao_as <token> <bao args...>: BAO_TOKEN from the first stdin line, rest of stdin to bao.
bao_as() {
  local token=$1; shift
  { printf '%s\n' "$token"; cat; } |
    kubectl -n "$NS" exec -i "$POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}

echo "==> Policies (as root, on $POD)"
for policy in eso-read eso-write demo-write; do
  bao_as "$ROOT_TOKEN" policy write "$policy" - < "openbao/policies/$policy.hcl"
done
echo "==> Role demo-writer"
bao_as "$ROOT_TOKEN" write auth/kubernetes/role/demo-writer \
  bound_service_account_names=demo-writer \
  bound_service_account_namespaces=eso-demo \
  token_policies=demo-write \
  token_ttl=5m token_max_ttl=5m </dev/null
echo "--- eso-write as stored in OpenBao:"
bao_as "$ROOT_TOKEN" policy read eso-write </dev/null
unset ROOT_TOKEN

echo
echo "==> Check as the ESO login (no root): managed-by marker on secret/pushed/policy-check"
JWT=$(kubectl -n external-secrets create token external-secrets --duration=10m)
ESO_TOKEN=$(printf '%s' "$JWT" |
  kubectl -n "$NS" exec -i "$POD" -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-)
unset JWT
bao_as "$ESO_TOKEN" kv metadata put -mount=secret -custom-metadata=managed-by=external-secrets pushed/policy-check </dev/null >/dev/null &&
  echo "write metadata secret/metadata/pushed/policy-check: allowed (expected)"
bao_as "$ESO_TOKEN" kv metadata delete -mount=secret pushed/policy-check </dev/null >/dev/null &&
  echo "delete metadata secret/metadata/pushed/policy-check: allowed (expected)"
if bao_as "$ESO_TOKEN" kv metadata put -mount=secret -custom-metadata=x=y demo/hello </dev/null >/dev/null 2>&1; then
  echo "write metadata secret/metadata/demo/hello: ALLOWED - policy is too wide!"; exit 1
else
  echo "write metadata secret/metadata/demo/hello: denied (expected)"
fi
bao_as "$ESO_TOKEN" token revoke -self </dev/null >/dev/null
unset ESO_TOKEN
