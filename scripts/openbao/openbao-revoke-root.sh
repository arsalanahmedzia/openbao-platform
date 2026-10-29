#!/usr/bin/env bash
# openbao-revoke-root.sh - revokes the OpenBao root token and checks it no longer works.
# Run it: bash scripts/openbao/openbao-revoke-root.sh (when OpenBao is configured; cleanup)
# Changes the cluster: yes: revokes the root token, asks first. Offers to delete
#   the Codespaces secret OPENBAO_ROOT_TOKEN.
#
# What it does:
#   1. Reads the token from OPENBAO_ROOT_TOKEN or ~/openbao-init.json and shows
#      its policies.
#        bao token lookup -format=json
#   2. Asks y/N, then revokes it.
#        bao token revoke -self
#   3. Checks the revoked token is refused.
#   4. Asks y/N, then deletes the Codespaces secret.
#        gh secret delete OPENBAO_ROOT_TOKEN --user --app codespaces
#
# What you should see: "policies of this token: ["root"]", "Success! Revoked
#   token", then "refused (expected): the root token is revoked".
# If it fails: "TOKEN STILL WORKS" means the revoke did not happen.
# Needs: kubectl, jq, gh. The token goes to the pod through stdin, never printed.
#   Afterwards openbao-configure.sh, openbao-policy-update.sh and the audit list
#   in openbao-audit-check.sh need a new root token first:
#   bash scripts/openbao/openbao-generate-root.sh (runbook section 6).
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
