#!/usr/bin/env bash
# Step 3 of the OpenBao stage: initialises OpenBao ONCE (5 key shares,
# threshold 3) and stores the result without ever printing it:
#   ~/openbao-init.json            (outside the repo, chmod 600; download a copy
#                                   and keep it somewhere safe)
#   Codespaces secrets OPENBAO_UNSEAL_KEYS (JSON list of the 5 shares) and
#                      OPENBAO_ROOT_TOKEN, so a new Codespace can unseal.
# Values only travel through files and stdin, never through the screen or the
# command line.
#   bash scripts/openbao/openbao-init.sh
set -euo pipefail

NS=openbao
POD=openbao-0
OUT="$HOME/openbao-init.json"
# The Codespace's own GITHUB_TOKEN cannot write Codespaces secrets; use the
# login from `gh auth login -s codespace:secrets` instead.
gh_user() { env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"; }

for tool in kubectl jq gh; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 1; }
done

echo "==> Checks before init (nothing is changed yet)"
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
gh_user secret list --user >/dev/null || {
  echo "gh cannot manage Codespaces secrets. Run:"
  echo "  env -u GITHUB_TOKEN gh auth login -h github.com -p https -s repo,codespace:secrets -w"
  exit 1
}
[[ -e "$OUT" ]] && { echo "$OUT already exists: OpenBao was probably initialised before. Stopping."; exit 1; }
# bao status exits with 2 while sealed, so ignore the exit code and read the JSON.
initialized=$(kubectl -n "$NS" exec "$POD" -- bao status -format=json 2>/dev/null | jq -r .initialized || true)
[[ "$initialized" == "false" ]] || { echo "$POD reports initialized=$initialized (expected false). Stopping."; exit 1; }
echo "ok (repo $REPO)"

echo "==> bao operator init (output goes straight to $OUT)"
umask 077
kubectl -n "$NS" exec "$POD" -- bao operator init -key-shares=5 -key-threshold=3 -format=json > "$OUT"
chmod 600 "$OUT"
jq -e '(.unseal_keys_b64 | length == 5) and (.root_token | length > 0)' "$OUT" >/dev/null \
  || { echo "$OUT does not contain 5 keys and a root token. Do NOT delete it; check it by hand."; exit 1; }

echo "==> Codespaces secrets (values via stdin)"
jq -c '.unseal_keys_b64' "$OUT" | gh_user secret set OPENBAO_UNSEAL_KEYS --user --app codespaces --repos "$REPO"
jq -j '.root_token' "$OUT"      | gh_user secret set OPENBAO_ROOT_TOKEN  --user --app codespaces --repos "$REPO"

echo
echo "initialised, keys saved to $OUT"
echo "Next: bash scripts/after-restart/openbao-unseal.sh"
