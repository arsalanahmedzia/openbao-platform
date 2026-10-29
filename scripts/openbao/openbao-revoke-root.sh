#!/usr/bin/env bash
# Hardening A5: revokes the OpenBao root token, checks that it no longer works,
# and offers to delete the Codespaces secret OPENBAO_ROOT_TOKEN.
# Token from OPENBAO_ROOT_TOKEN or ~/openbao-init.json, passed to the pod via
# stdin, never printed. Asks before doing anything.
# After this, scripts that need root (openbao-configure.sh,
# openbao-policy-update.sh, openbao-audit-check.sh's audit list) need a new root
# token first: bash scripts/openbao/openbao-generate-root.sh (runbook section 6).
#   bash scripts/openbao/openbao-revoke-root.sh
set -euo pipefail

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
INIT_FILE="$HOME/openbao-init.json"

if [[ -n "${OPENBAO_ROOT_TOKEN:-}" ]]; then
  TOKEN=$OPENBAO_ROOT_TOKEN; SOURCE="Codespaces secret OPENBAO_ROOT_TOKEN"
elif [[ -r "$INIT_FILE" ]]; then
  TOKEN=$(jq -r .root_token "$INIT_FILE"); SOURCE="$INIT_FILE"
else
  echo "no root token: set OPENBAO_ROOT_TOKEN or provide $INIT_FILE"; exit 1
fi
POD=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "no active OpenBao pod (unsealed?)"; exit 1; }

# with_token <bao args...>: BAO_TOKEN from stdin, never on a command line
with_token() {
  printf '%s\n' "$TOKEN" |
    kubectl -n "$NS" exec -i "$POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}

echo "root token from: $SOURCE"
echo "policies of this token: $(with_token token lookup -format=json | jq -c .data.policies)"
read -r -p "Revoke this token now? A new one needs 3 key shares (generate-root). [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted, nothing changed"; exit 1; }

with_token token revoke -self
echo
echo "==> Check: the revoked token must be refused"
if with_token token lookup >/dev/null 2>&1; then
  echo "TOKEN STILL WORKS - not revoked"; exit 1
fi
echo "refused (expected): the root token is revoked"
unset TOKEN

echo
read -r -p "Delete the Codespaces secret OPENBAO_ROOT_TOKEN (now useless)? [y/N] " answer
if [[ "$answer" == y || "$answer" == Y ]]; then
  env -u GITHUB_TOKEN -u GH_TOKEN gh secret delete OPENBAO_ROOT_TOKEN --user --app codespaces
fi
echo "The root_token in $INIT_FILE (and in your downloaded copy) is useless now; the unseal keys there are still needed."
