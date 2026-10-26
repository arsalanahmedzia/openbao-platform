#!/usr/bin/env bash
# Hardening A4 (risk R11): after `git push`, rolls the OpenBao pods onto the
# config with the declarative stdout audit device (scripts/openbao-tls-rollout.sh
# restarts only pods on an old StatefulSet revision and unseals them), lists the
# audit devices, makes one read of secret/demo/hello as the ESO login and shows
# the matching audit entry from the active pod's log: who, what, and that the
# value and the token are HMAC hashes, not plain.
# Root token only for the read-only `bao audit list` (needs sudo); tokens go to
# the pod through stdin and are never printed.
#   bash scripts/openbao-audit-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
INIT_FILE="$HOME/openbao-init.json"

echo "==> Roll pods onto the new config (unseals each restarted pod)"
bash scripts/openbao-tls-rollout.sh

POD=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "no active OpenBao pod"; exit 1; }
# bao_with <token> <bao args...>: BAO_TOKEN from the first stdin line
bao_with() {
  local token=$1; shift
  printf '%s\n' "$token" |
    kubectl -n "$NS" exec -i "$POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}

echo
echo "==> Audit devices (as root, read-only list)"
ROOT_TOKEN=${OPENBAO_ROOT_TOKEN:-$(jq -r .root_token "$INIT_FILE")}
bao_with "$ROOT_TOKEN" audit list -detailed
unset ROOT_TOKEN

echo
echo "==> One read of secret/demo/hello as the ESO login (on $POD)"
JWT=$(kubectl -n external-secrets create token external-secrets --duration=10m)
ESO_TOKEN=$(printf '%s' "$JWT" |
  kubectl -n "$NS" exec -i "$POD" -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-)
unset JWT
echo "value returned to the client: $(bao_with "$ESO_TOKEN" kv get -mount=secret -field=message demo/hello)"
bao_with "$ESO_TOKEN" token revoke -self >/dev/null
unset ESO_TOKEN
sleep 2

echo
echo "==> Audit entry for that read in the log of $POD (newest response)"
LOG=$(kubectl -n "$NS" logs "$POD" --since=2m)
jq -R 'fromjson? | select(.type == "response" and .request.path == "secret/data/demo/hello")' <<<"$LOG" |
  jq -s 'last | {
      time,
      type,
      who: .auth.display_name,
      policies: .auth.policies,
      operation: .request.operation,
      path: .request.path,
      client_token: ((.auth.client_token // "") | .[0:24] + "..."),
      returned_message: ((.response.data.data.message // "") | .[0:24] + "...")
    }'

echo
echo "==> Is the plain value anywhere in the recent log? (expect 0)"
grep -c 'hello-from-openbao' <<<"$LOG" || true
