#!/usr/bin/env bash
# openbao-init.sh - initialises OpenBao once and stores the key shares and root token without printing them.
#
# In plain words:
#   A new OpenBao must be initialised once, before it can hold any secret.
#   Initialising creates the master key, splits it into 5 key shares (any 3
#   unlock OpenBao) and creates the root token, which may do everything.
#   OpenBao shows these values only once, so they must be saved safely at that
#   moment.
#
#   This script checks first that it is safe to run (gh can write Codespaces
#   secrets, no old init file exists, OpenBao reports it is not initialised
#   yet). Then it runs the init and writes the output straight into
#   ~/openbao-init.json, outside the repository, readable only by you. Finally
#   it stores the 5 shares and the root token as Codespaces secrets, so a new
#   Codespace can unseal OpenBao. The values never appear on the screen.
#   Download ~/openbao-init.json and keep it outside the Codespace.
#
# Run it: bash scripts/openbao/openbao-init.sh (once per new OpenBao, i.e. empty database)
# Changes the cluster: yes: initialises OpenBao (5 key shares, threshold 3).
#   Also writes ~/openbao-init.json and two Codespaces secrets.
#
# What it does:
#   1. Checks first, changes nothing yet: gh can manage Codespaces secrets,
#      ~/openbao-init.json does not exist, openbao-0 reports initialized=false.
#        gh secret list --user
#        kubectl -n openbao exec openbao-0 -- bao status -format=json
#   2. Initialises OpenBao; the output goes straight into ~/openbao-init.json
#      (outside the repo, chmod 600).
#        kubectl -n openbao exec openbao-0 -- bao operator init -key-shares=5 -key-threshold=3 -format=json
#   3. Stores the 5 shares and the root token as Codespaces secrets through
#      stdin, so a new Codespace can unseal.
#        gh secret set OPENBAO_UNSEAL_KEYS --user --app codespaces --repos <repo>
#        gh secret set OPENBAO_ROOT_TOKEN  --user --app codespaces --repos <repo>
#
# What you should see: "ok (repo ...)", then "initialised, keys saved to
#   ~/openbao-init.json" and "Next: bash scripts/after-restart/openbao-unseal.sh".
#   Download ~/openbao-init.json and keep it outside the Codespace.
# If it fails: "gh cannot manage Codespaces secrets" prints the gh auth login
#   command to run. "already exists" or "initialized=true": OpenBao was
#   initialised before; the script stops without changing anything.
# Needs: kubectl, jq, gh logged in with codespace:secrets (the Codespace's own
#   GITHUB_TOKEN cannot write Codespaces secrets).
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
