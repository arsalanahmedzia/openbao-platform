#!/usr/bin/env bash
# openbao-configure.sh - configures OpenBao for External Secrets (storage, login, policies, roles).
#
# In plain words:
#   A freshly unsealed OpenBao is empty: it has no place for secrets, no way
#   for External Secrets to log in, and no rules. This script sets all of that
#   up, using the root token for the last planned time.
#
#   It switches on the secret storage at secret/ (KV v2, which keeps older
#   versions of each value). It switches on the Kubernetes login, so a pod can
#   log in with its Kubernetes identity (its service account) instead of a
#   stored password; OpenBao checks that identity by asking the Kubernetes
#   API. It loads the three policies from openbao/policies/ (what a login may
#   read or write), creates the roles that tie the ESO service account and the
#   demo writer to those policies, and writes the demo secret
#   secret/demo/hello. Last, it logs in as External Secrets to prove the login
#   works. Every step checks first, so running it again changes nothing.
#
# Run it: bash scripts/openbao/openbao-configure.sh (once after the first unseal; safe to run again)
# Changes the cluster: yes: writes OpenBao's configuration with the root token
#   (the last planned use of it, see ADR 0004). Every step checks first or
#   overwrites with the same content.
#
# What it does:
#   1. Checks the ESO service account exists and finds the active pod.
#        kubectl -n external-secrets get sa external-secrets
#   2. Enables KV v2 at secret/ and Kubernetes auth (OpenBao checks logins with
#      its own service account).
#        bao secrets enable -path=secret -version=2 kv
#        bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443
#   3. Writes the policies from openbao/policies/ (eso-read, eso-write, demo-write).
#        bao policy write <policy> - < openbao/policies/<policy>.hcl
#   4. Creates the role external-secrets (for external-secrets/external-secrets,
#      policies eso-read and eso-write, token TTL 15m) and the role demo-writer
#      (for eso-demo/demo-writer, TTL 5m, used by the refresh test).
#   5. Writes the test secret secret/demo/hello (message hello-from-openbao).
#        bao kv put -mount=secret demo/hello message=hello-from-openbao
#   6. Logs in as the ESO service account, without the root token.
#        kubectl -n external-secrets create token external-secrets --duration=10m
#        bao write -field=token auth/kubernetes/login role=external-secrets jwt=-
#   Tokens go to the pod through stdin, never printed, never on a command line.
#
# What you should see: "already enabled" or the enable output per step, the
#   role settings, the test secret, then "login ok" with the policies
#   ["default","eso-read","eso-write"].
# If it fails: "service account ... not found" lists the existing ones; re-run
#   with ESO_SA=<name>. "no active OpenBao pod": unseal first.
# Needs: kubectl, jq, OPENBAO_ROOT_TOKEN or ~/openbao-init.json. Optional
#   environment: ESO_NS and ESO_SA (default external-secrets for both).
set -euo pipefail
cd "$(dirname "$0")/../.."

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
  echo "Re-run with ESO_SA=<name> bash scripts/openbao/openbao-configure.sh"; exit 1
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
for policy in eso-read eso-write demo-write; do
  root policy write "$policy" - < "openbao/policies/$policy.hcl"
done

echo "==> 4. Role external-secrets"
root write auth/kubernetes/role/external-secrets \
  bound_service_account_names="$ESO_SA" \
  bound_service_account_namespaces="$ESO_NS" \
  token_policies=eso-read,eso-write \
  token_ttl=15m token_max_ttl=1h </dev/null
root read auth/kubernetes/role/external-secrets </dev/null |
  grep -E '^(bound_service_account_names|bound_service_account_namespaces|token_policies|token_ttl|token_max_ttl) '

echo "==> 4b. Role demo-writer (refresh test; the SA comes from Git, apps/external-secrets)"
root write auth/kubernetes/role/demo-writer \
  bound_service_account_names=demo-writer \
  bound_service_account_namespaces=eso-demo \
  token_policies=demo-write \
  token_ttl=5m token_max_ttl=5m </dev/null

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
