#!/usr/bin/env bash
# Run at the start of every work session, after the Codespace was stopped and started:
#   bash scripts/after-restart/resume.sh
# It restarts the kind node containers, re-adds the firewall rule that is lost on
# restart (see docs/environment.md), checks DNS in the nodes and waits for Ready.
set -euo pipefail

CLUSTER=openbao-platform

echo "==> Starting kind node containers"
ids=$(docker ps -aq --filter "name=${CLUSTER}-")
if [[ -z "$ids" ]]; then
  echo "No kind containers found. Create the cluster with: bash scripts/setup/bootstrap.sh"
  exit 1
fi
# shellcheck disable=SC2086
docker start $ids >/dev/null
kind export kubeconfig --name "$CLUSTER" >/dev/null

echo "==> Firewall rule for the kind bridge"
BR="br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)"
for dir in -i -o; do
  sudo iptables-legacy -C FORWARD "$dir" "$BR" -j ACCEPT 2>/dev/null \
    || sudo iptables-legacy -I FORWARD "$dir" "$BR" -j ACCEPT
done
echo "ok ($BR)"

echo "==> DNS inside the nodes"
DNS="$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf)"
DNS="${DNS:-8.8.8.8}"
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" getent hosts ghcr.io >/dev/null 2>&1 \
    || docker exec "$node" sh -c "echo 'nameserver $DNS' > /etc/resolv.conf"
done
echo "ok"

echo "==> Waiting for nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Docker can give the node containers different IPs on a restart; kindnet then
# may hand out pod IPs from another node's range and pod traffic (DNS first)
# breaks. Check and, if needed, repair (asks before recreating pods).
echo "==> Pod network check (node IPs can change on a restart)"
sleep 30   # let kindnet and the pods start
bash "$(dirname "$0")/kind-fix-pod-network.sh"

echo
echo "Cluster is back. Check Flux with: flux get kustomizations"
echo "OpenBao pods restart SEALED. Once they are Running, unseal them with:"
echo "  bash scripts/after-restart/openbao-unseal.sh"
