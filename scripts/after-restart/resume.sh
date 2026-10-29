#!/usr/bin/env bash
# resume.sh - brings the kind cluster back after the Codespace was stopped and started.
#
# When the Codespace stops, the four kind node containers stop with it, and
# some settings are lost. This script brings the cluster back so you can
# work again. It starts the node containers, points kubectl at the cluster,
# adds back a firewall rule the host forgets on every restart (without it
# the nodes cannot reach the internet), and repairs DNS inside a node if
# that node cannot resolve names.
#
# Then it waits until all nodes are Ready and runs kind-fix-pod-network.sh,
# because Docker can give the nodes new IP addresses on a restart, which
# breaks the pod network (risk R27). It does not unseal OpenBao: the OpenBao
# pods come back sealed, so the last line tells you to run
# openbao-unseal.sh.
#
# Run it: bash scripts/after-restart/resume.sh (at the start of every work session after a Codespace restart)
# Changes the cluster: yes: starts the node containers, re-adds a firewall rule,
#   may fix DNS in the nodes, and runs the pod-network fix (which asks first).
#
# What it does:
#   1. Starts the kind node containers and writes the kubeconfig.
#        docker start <node containers> ; kind export kubeconfig --name openbao-platform
#   2. Re-adds the firewall rule for the kind bridge that a restart removes
#      (see docs/environment.md).
#        sudo iptables-legacy -I FORWARD -i|-o br-<id> -j ACCEPT
#   3. Sets the host's DNS server in a node that cannot resolve names.
#        docker exec <node> getent hosts ghcr.io
#   4. Waits until all nodes are Ready.
#        kubectl wait --for=condition=Ready nodes --all --timeout=300s
#   5. After 30 s, checks the pod network: node IPs can change on a restart
#      (risk R27).
#        bash "$(dirname "$0")/kind-fix-pod-network.sh"
#
# What you should see: "ok" for the firewall rule and DNS, the nodes Ready,
#   "none: pod network is consistent" (or the fix), then "Cluster is back." and
#   the reminder to unseal OpenBao.
# If it fails: "No kind containers found" means the cluster does not exist;
#   create it with scripts/setup/bootstrap.sh.
# Needs: docker, kind, kubectl, jq, sudo (for iptables-legacy).
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
