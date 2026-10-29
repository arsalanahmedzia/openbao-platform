#!/usr/bin/env bash
# github-access-check.sh - shows which GitHub access this setup uses, without printing any token.
#
# In plain words:
#   This script answers one question for risk R08: which GitHub access does
#   this setup use, and how much may it do? Write access to the repository is
#   enough to change the cluster, because Flux applies whatever is in Git.
#
#   It looks at two tokens, FLUX_GITHUB_TOKEN and your gh login, and shows for
#   each only the type (from the first letters of the token), the rights
#   GitHub reports for it and its expiry date; the token itself is never
#   printed. Then it lists the deploy keys of the repository (Flux bootstrap
#   creates one) and the branch protection on main. It only reads from the
#   GitHub API and does not touch the cluster.
#
# Run it: bash scripts/checks/github-access-check.sh (to review access, risk R08)
# Changes the cluster: no. It calls only the GitHub API.
#
# What it does:
#   1. For FLUX_GITHUB_TOKEN and the gh login: the type prefix (gho_ = gh CLI
#      OAuth token, ghp_ = classic PAT, github_pat_ = fine-grained token), the
#      scopes and the expiry, from the response headers of the GitHub API.
#        curl -sS -o /dev/null -D - -H "Authorization: token <token>" https://api.github.com/user
#   2. The deploy keys of the repository (Flux bootstrap creates one).
#        gh api repos/<repo>/keys
#   3. The branch protection on main.
#        gh api repos/<repo>/branches/main/protection
#
# What you should see: per token "type prefix", "status", "scopes", "expires";
#   the deploy keys with read_only and created; the branch protection or "none".
# If it fails: "not set in this Codespace" means the Codespaces secret appears
#   only after a Codespace restart. gh errors: run gh auth login.
# Needs: gh (logged in), curl.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
# The Codespace's own GITHUB_TOKEN is not what we want to inspect.
gh_user() { env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"; }

# describe <label> <token>: prefix, scopes, expiry (headers only, body discarded)
describe() {
  local label=$1 token=$2 prefix headers
  prefix="${token%%_*}_"
  [[ "$token" == github_pat_* ]] && prefix=github_pat_
  headers=$(curl -sS -o /dev/null -D - -H "Authorization: token $token" https://api.github.com/user)
  echo "$label"
  echo "  type prefix: $prefix"
  echo "  status:      $(head -1 <<<"$headers" | tr -d '\r')"
  echo "  scopes:      $(grep -i '^x-oauth-scopes:' <<<"$headers" | cut -d: -f2- | tr -d '\r' || echo '(none sent: fine-grained or invalid)')"
  echo "  expires:     $(grep -i '^github-authentication-token-expiration:' <<<"$headers" | cut -d: -f2- | tr -d '\r' || echo '(no expiry reported)')"
}

echo "==> Tokens (values never printed)"
if [[ -n "${FLUX_GITHUB_TOKEN:-}" ]]; then
  describe "FLUX_GITHUB_TOKEN (Codespaces secret, as injected into this Codespace)" "$FLUX_GITHUB_TOKEN"
else
  echo "FLUX_GITHUB_TOKEN: not set in this Codespace (secrets appear only after a restart)"
fi
describe "gh login (used by the scripts for Codespaces secrets)" "$(gh_user auth token)"

echo
echo "==> Deploy keys of $REPO (Flux bootstrap creates one)"
gh_user api "repos/$REPO/keys" --jq '.[] | "  \(.title)  read_only=\(.read_only)  created=\(.created_at)"'

echo
echo "==> Branch protection on main"
if gh_user api "repos/$REPO/branches/main/protection" >/dev/null 2>&1; then
  gh_user api "repos/$REPO/branches/main/protection" \
    --jq '"  force pushes allowed: \(.allow_force_pushes.enabled)  deletion allowed: \(.allow_deletions.enabled)  required reviews: \(.required_pull_request_reviews != null)"'
else
  echo "  none (or not visible with this token)"
fi
