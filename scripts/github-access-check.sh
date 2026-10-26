#!/usr/bin/env bash
# Hardening A3 (risk R08): shows, without printing any token, which GitHub
# access this setup really uses:
#   - type of FLUX_GITHUB_TOKEN and of the gh login (prefix only: gho_ = gh CLI
#     OAuth token, ghp_ = classic PAT, github_pat_ = fine-grained token),
#     their scopes (X-OAuth-Scopes header; fine-grained tokens send none) and
#     expiry if GitHub reports one
#   - deploy keys of the repository (public keys: title, read-only, created)
#   - branch protection on main
# Calls only the GitHub API; does not touch the cluster.
#   bash scripts/github-access-check.sh
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
