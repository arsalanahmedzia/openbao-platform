#!/usr/bin/env bash
# Hardening A5: creates a NEW OpenBao root token from 3 of the 5 key shares
# (generate-root with a one-time password) and stores it directly as the
# Codespaces secret OPENBAO_ROOT_TOKEN. Use it when a root token is needed
# after scripts/openbao-revoke-root.sh. Revoke the new token again when done.
# UNTESTED: written from the OpenBao v2.7.1 CLI source
# (internal/command/operator_generate_root.go): "-" as the key argument reads
# the share from stdin, -decode=- reads the encoded token from stdin.
# Key shares from OPENBAO_UNSEAL_KEYS or ~/openbao-init.json, via stdin only;
# the new token is never printed. The one-time password is an argument inside
# the pod; on its own it reveals nothing (it is XORed with the token).
#   bash scripts/openbao-generate-root.sh
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
echo "Revoke it when done: bash scripts/openbao-revoke-root.sh"
