#!/usr/bin/env bash
# openbao-generate-root.sh - creates a new OpenBao root token from 3 key shares and stores it as a Codespaces secret.
#
# In plain words:
#   The root token can do everything in OpenBao, so it should not exist while
#   it is not needed (see openbao-revoke-root.sh). When it is needed again,
#   for example to change a policy, OpenBao can create a new one, but only
#   with 3 of the 5 key shares. This script does that.
#
#   It asks y/N first. Then it starts the procedure with a one-time password,
#   gives OpenBao 3 key shares through stdin, and gets back the new token in
#   encoded form. It decodes the token and sends it straight to the Codespaces
#   secret OPENBAO_ROOT_TOKEN, so it never appears on the screen. Revoke the
#   new token again when you are done. This script was never run; it is
#   written from the OpenBao source code.
#
# Run it: bash scripts/openbao/openbao-generate-root.sh (only when a root token is needed after openbao-revoke-root.sh)
# Changes the cluster: yes: creates a new root token, asks first. Stores it as
#   the Codespaces secret OPENBAO_ROOT_TOKEN; revoke it again when done.
# UNTESTED: written from the OpenBao v2.7.1 CLI source
#   (internal/command/operator_generate_root.go): "-" as the key argument reads
#   the share from stdin, -decode=- reads the encoded token from stdin.
#
# What it does:
#   1. Reads the key shares from OPENBAO_UNSEAL_KEYS or ~/openbao-init.json and
#      finds the active pod. Asks y/N.
#   2. Starts the procedure with a one-time password (on its own it reveals
#      nothing; it is XORed with the token).
#        bao operator generate-root -generate-otp
#        bao operator generate-root -init -otp=<OTP> -format=json
#   3. Gives 3 key shares through stdin.
#        bao operator generate-root -nonce=<nonce> -format=json -
#   4. Decodes the token and sends it straight to the Codespaces secret, never
#      to the screen.
#        bao operator generate-root -decode=- -otp=<OTP> | gh secret set OPENBAO_ROOT_TOKEN --user --app codespaces --repos <repo>
#
# What you should see: "nonce: ...", "progress: 1/3" to "3/3", then "New root
#   token stored." It appears as an environment variable after a Codespace restart.
# If it fails: "no encoded token after 3 shares" prints the cancel command
#   (bao operator generate-root -cancel); a started attempt blocks new ones.
# Needs: kubectl, jq, gh logged in with codespace:secrets, the key shares.
set -euo pipefail

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
INIT_FILE="$HOME/openbao-init.json"

if [[ -n "${OPENBAO_UNSEAL_KEYS:-}" ]]; then
  mapfile -t KEYS < <(jq -r '.[]' <<<"$OPENBAO_UNSEAL_KEYS")
elif [[ -r "$INIT_FILE" ]]; then
  mapfile -t KEYS < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
else
  echo "no key shares: set OPENBAO_UNSEAL_KEYS or provide $INIT_FILE"; exit 1
fi
POD=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "no active OpenBao pod (unsealed?)"; exit 1; }
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
bao_pod() { kubectl -n "$NS" exec -i "$POD" -- bao "$@"; }

read -r -p "Create a new root token and store it as OPENBAO_ROOT_TOKEN? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted, nothing changed"; exit 1; }

echo "==> Start (one-time password, nonce)"
OTP=$(bao_pod operator generate-root -generate-otp </dev/null)
NONCE=$(bao_pod operator generate-root -init -otp="$OTP" -format=json </dev/null | jq -r .nonce)
echo "nonce: $NONCE"

echo "==> Provide 3 key shares (stdin)"
ENCODED=""
for key in "${KEYS[@]:0:3}"; do
  out=$(printf '%s' "$key" | bao_pod operator generate-root -nonce="$NONCE" -format=json -)
  echo "progress: $(jq -r '"\(.progress)/\(.required)"' <<<"$out")"
  ENCODED=$(jq -r '.encoded_token // .encoded_root_token // empty' <<<"$out")
done
[[ -n "$ENCODED" ]] || { echo "no encoded token after 3 shares; cancel with: kubectl -n $NS exec $POD -- bao operator generate-root -cancel"; exit 1; }

echo "==> Decode and store as Codespaces secret (not printed)"
printf '%s' "$ENCODED" | bao_pod operator generate-root -decode=- -otp="$OTP" | tr -d '\r\n' |
  env -u GITHUB_TOKEN -u GH_TOKEN gh secret set OPENBAO_ROOT_TOKEN --user --app codespaces --repos "$REPO"
unset OTP ENCODED
echo "New root token stored. It appears as an environment variable after a Codespace restart."
echo "Revoke it when done: bash scripts/openbao/openbao-revoke-root.sh"
