#!/usr/bin/env bash
# openbao-audit-check.sh - shows that the OpenBao audit log records a read with the value hashed.
#
# OpenBao writes an audit log: one line for every request and its answer,
# with every secret value and token replaced by a hash. This script shows
# that the log really works and leaks nothing (risk R11).
#
# First it runs openbao-tls-rollout.sh, so the pods use the configuration
# that contains the audit device. Then it lists the audit devices, reads the
# demo secret once as the External Secrets login, and looks up exactly that
# read in the active pod's log. It prints who asked, which path, and the
# hashed token and value, and it counts how often the plain demo value
# appears in the log; the answer must be 0.
#
# Run it: bash scripts/openbao/openbao-audit-check.sh (after git push of the audit config; risk R11)
# Changes the cluster: yes: runs openbao-tls-rollout.sh, which restarts outdated
#   pods and unseals them.
#
# What it does:
#   1. Rolls the pods onto the config with the stdout audit device.
#        bash scripts/openbao/openbao-tls-rollout.sh
#   2. Lists the audit devices with the root token (read-only).
#        bao audit list -detailed
#   3. Reads secret/demo/hello once as the ESO login, then revokes that token.
#        bao kv get -mount=secret -field=message demo/hello
#   4. Shows the matching audit entry from the active pod's log (who, what) and
#      counts the plain value in the log.
#        kubectl -n openbao logs <active pod> --since=2m
#
# What you should see: the device "stdout", the entry with the ESO login and
#   path secret/data/demo/hello where client_token and returned_message are
#   hashes (shown cut to 24 characters), and the count 0 for the plain value.
# If it fails: no entry: the device is not active; check the rollout output.
# Needs: kubectl, jq, OPENBAO_ROOT_TOKEN or ~/openbao-init.json. Tokens go to
#   the pod through stdin and are never printed.
set -euo pipefail
cd "$(dirname "$0")/../.."

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
INIT_FILE="$HOME/openbao-init.json"

echo "==> Roll pods onto the new config (unseals each restarted pod)"
bash scripts/openbao/openbao-tls-rollout.sh

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
