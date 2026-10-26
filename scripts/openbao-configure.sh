#!/usr/bin/env bash
# Step 5 of the OpenBao stage: configures OpenBao for External Secrets.
# Safe to run again (every step either checks first or overwrites with the
# same content). Uses the root token for the last time; see ADR 0004.
#   - KV v2 secrets engine at secret/
#   - Kubernetes auth method (in-cluster, OpenBao's own SA reviews tokens)
#   - policies eso-read and eso-write
#   - role external-secrets for SA external-secrets/external-secrets
#   - test secret secret/demo/hello, then a login AS the ESO service account
# Tokens go to the pod through stdin, never printed, never on a command line.
#   bash scripts/openbao-configure.sh
set -euo pipefail

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
ESO_NS=${ESO_NS:-external-secrets}
ESO_SA=${ESO_SA:-external-secrets}
INIT_FILE="$HOME/openbao-init.json"

for tool in kubectl jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 1; }
done

echo "==> Checks (nothing is changed yet)"
kubectl -n "$ESO_NS" get sa "$ESO_SA" >/dev/null || {
  echo "service account $ESO_NS/$ESO_SA not found. Existing ones:"
  kubectl -n "$ESO_NS" get sa
  echo "Re-run with ESO_SA=<name> bash scripts/openbao-configure.sh"; exit 1
}
if [[ -n "${OPENBAO_ROOT_TOKEN:-}" ]]; then
  ROOT_TOKEN=$OPENBAO_ROOT_TOKEN
elif [[ -r "$INIT_FILE" ]]; then
  ROOT_TOKEN=$(jq -r .root_token "$INIT_FILE")
else
  echo "no root token: set OPENBAO_ROOT_TOKEN or provide $INIT_FILE"; exit 1
fi
POD=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "no active OpenBao pod (unsealed?)"; exit 1; }
echo "ok (active pod $POD, ESO service account $ESO_NS/$ESO_SA)"

# bao_as <token> <bao args...>: runs bao in the active pod with BAO_TOKEN read
# from the first line of stdin; the rest of stdin is passed on to bao.
bao_as() {
  local token=$1; shift
  { printf '%s\n' "$token"; cat; } |
    kubectl -n "$NS" exec -i "$POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}
root() { bao_as "$ROOT_TOKEN" "$@"; }

echo "==> 1. KV v2 at secret/"
if root secrets list -format=json </dev/null | jq -e 'has("secret/")' >/dev/null; then
  echo "already enabled"
else
  root secrets enable -path=secret -version=2 kv </dev/null
fi

echo "==> 2. Kubernetes auth"
if root auth list -format=json </dev/null | jq -e 'has("kubernetes/")' >/dev/null; then
  echo "already enabled"
else
  root auth enable kubernetes </dev/null
fi
root write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443 </dev/null

echo "==> 3. Policies"
root policy write eso-read - <<'EOF'
# Read every KV v2 secret (data) and list/read their metadata.
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
root policy write eso-write - <<'EOF'
# Write (PushSecret) only below secret/pushed/.
path "secret/data/pushed/*" {
  capabilities = ["create", "update"]
}
EOF

echo "==> 4. Role external-secrets"
root write auth/kubernetes/role/external-secrets \
  bound_service_account_names="$ESO_SA" \
  bound_service_account_namespaces="$ESO_NS" \
  token_policies=eso-read,eso-write \
  token_ttl=15m token_max_ttl=1h </dev/null
root read auth/kubernetes/role/external-secrets </dev/null |
  grep -E '^(bound_service_account_names|bound_service_account_namespaces|token_policies|token_ttl|token_max_ttl) '

echo "==> 5. Test secret secret/demo/hello"
root kv put -mount=secret demo/hello message=hello-from-openbao </dev/null
root kv get -mount=secret demo/hello </dev/null
unset ROOT_TOKEN

echo "==> 6. Login as $ESO_NS/$ESO_SA through Kubernetes auth (no root token)"
SA_JWT=$(kubectl -n "$ESO_NS" create token "$ESO_SA" --duration=10m)
ESO_TOKEN=$(printf '%s' "$SA_JWT" |
  kubectl -n "$NS" exec -i "$POD" -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-)
unset SA_JWT
echo "login ok; policies of this token:"
bao_as "$ESO_TOKEN" token lookup -format=json </dev/null | jq -c '.data.policies'
echo "read secret/demo/hello:"
bao_as "$ESO_TOKEN" kv get -mount=secret -field=message demo/hello </dev/null; echo
echo "write secret/pushed/check (allowed):"
bao_as "$ESO_TOKEN" kv put -mount=secret pushed/check ok=true </dev/null >/dev/null && echo "allowed (expected)"
echo "write secret/demo/denied (must be denied):"
if bao_as "$ESO_TOKEN" kv put -mount=secret demo/denied ok=true </dev/null >/dev/null 2>&1; then
  echo "ALLOWED - policy is too wide!"; exit 1
else
  echo "denied (expected)"
fi
bao_as "$ESO_TOKEN" token revoke -self </dev/null >/dev/null
unset ESO_TOKEN

echo
echo "Configuration done. The root token is not needed any more (see runbook: revoke it)."
