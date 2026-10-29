#!/usr/bin/env bash
# openbao-failover-test.sh - deletes the active OpenBao pod and shows a standby takes over.
#
# In plain words:
#   OpenBao runs as 3 pods: one active pod answers all requests, and two
#   standbys wait. This test answers: does a standby take over when the active
#   pod is lost? It reads the demo secret as External Secrets, deletes the
#   active pod, and waits until another pod has become active.
#
#   Then it reads the secret again through the new active pod, shows that the
#   deleted pod came back sealed, unseals it, and shows it joined as a
#   standby. The output also goes to docs/evidence/04-failover.txt.
#
# Run it: bash scripts/failure-tests/openbao-failover-test.sh (after the OpenBao stage; output also in docs/evidence/04-failover.txt)
# Changes the cluster: breaks something on purpose, asks first: deletes the
#   active OpenBao pod; the StatefulSet recreates it sealed and the script unseals it.
#
# What it does:
#   1. Reads secret/demo/hello as the External Secrets service account through
#      the active pod (no root token; the login token stays in a shell variable).
#        kubectl -n external-secrets create token external-secrets --duration=10m
#        bao write -field=token auth/kubernetes/login role=external-secrets jwt=-
#   2. Deletes the active pod.
#        kubectl -n openbao delete pod <active pod> --wait=false
#   3. Waits up to 60 s until a standby has become active, reads the secret again.
#   4. Shows the replacement pod comes back SEALED.
#        kubectl -n openbao exec <pod> -- bao status
#   5. Unseals it and shows it joins as standby.
#        bash scripts/after-restart/openbao-unseal.sh
#
# What you should see: the secret value hello-from-openbao twice, "new active
#   pod: ... (after about N s)", "Sealed true" for the replacement, then the old
#   pod back as standby.
# If it fails: "no new active pod after 60 s": check the other pods with
#   kubectl -n openbao get pods -L openbao-active,openbao-sealed.
# Needs: kubectl, the unseal keys.
set -euo pipefail
cd "$(dirname "$0")/../.."

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
OUT=docs/evidence/04-failover.txt

active_pod() { kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }
labels() { kubectl -n "$NS" get pods -o wide -L openbao-active,openbao-sealed; }

# read_secret <pod>: log in as the ESO service account through Kubernetes auth
# on <pod> and read secret/demo/hello. Tokens only in variables / stdin.
read_secret() {
  local pod=$1 jwt token
  jwt=$(kubectl -n external-secrets create token external-secrets --duration=10m)
  token=$(printf '%s' "$jwt" |
    kubectl -n "$NS" exec -i "$pod" -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-)
  printf '%s\n' "$token" |
    kubectl -n "$NS" exec -i "$pod" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; bao kv get -mount=secret -field=message demo/hello; echo; bao token revoke -self >/dev/null'
}

OLD=$(active_pod)
[[ -n "$OLD" ]] || { echo "no active pod; unseal first"; exit 1; }
read -r -p "This deletes the ACTIVE pod $OLD. Continue? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted"; exit 1; }

exec > >(tee "$OUT") 2>&1
echo "# OpenBao failover test, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "==> Before: active pod is $OLD"
labels
echo
echo "==> Read secret/demo/hello as external-secrets (via $OLD)"
read_secret "$OLD"

echo
echo "==> Deleting the active pod $OLD"
start=$(date +%s)
kubectl -n "$NS" delete pod "$OLD" --wait=false

echo
echo "==> Waiting for a standby to take over"
NEW=""
for _ in $(seq 60); do
  NEW=$(active_pod)
  [[ -n "$NEW" && "$NEW" != "$OLD" ]] && break
  NEW=""; sleep 1
done
[[ -n "$NEW" ]] || { echo "no new active pod after 60 s"; exit 1; }
echo "new active pod: $NEW (after about $(( $(date +%s) - start )) s)"

echo
echo "==> Read secret/demo/hello again (via $NEW)"
read_secret "$NEW"

echo
echo "==> Replacement pod $OLD: waiting until Running, it must be SEALED"
for _ in $(seq 60); do
  [[ "$(kubectl -n "$NS" get pod "$OLD" -o jsonpath='{.status.phase}' 2>/dev/null)" == Running ]] && break
  sleep 2
done
sleep 5
kubectl -n "$NS" exec "$OLD" -- bao status | grep -E '^(Initialized|Sealed|HA Enabled)' || true
labels

echo
echo "==> Unseal the replacement pod"
bash scripts/after-restart/openbao-unseal.sh

echo
echo "==> After: $NEW active, $OLD back as standby"
labels
