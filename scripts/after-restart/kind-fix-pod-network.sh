#!/usr/bin/env bash
# kind-fix-pod-network.sh - repairs the kind pod network after the node containers got new IP addresses.
#
# After a Codespace restart Docker can give the node containers different IP
# addresses. kindnet, the program that hands out pod IPs in kind, then keeps
# using the old ranges: pods get addresses that belong to another node, DNS
# stops working and OpenBao crashes because it cannot find PostgreSQL. This
# script finds that state and repairs it.
#
# First it compares, on every node, the range kindnet hands out with the
# range Kubernetes gave the node, and restarts kindnet if they differ. Then
# it lists the pods whose IP is outside their node's range. If there are
# none, it stops and changes nothing. Otherwise it asks y/N and recreates
# those pods, because a new pod gets a new, correct IP: first CoreDNS (names
# must work first), then the other pods, then all affected PostgreSQL pods
# together, then OpenBao. OpenBao comes back sealed, so unseal it
# afterwards.
#
# Run it: bash scripts/after-restart/kind-fix-pod-network.sh (resume.sh runs it; also by hand when DNS or pods fail after a restart)
# Changes the cluster: yes: may restart kindnet and recreate pods, asks first
#   before it recreates any pod. OpenBao pods come back sealed.
#
# What it does:
#   1. For each node, compares the pod range kindnet hands out with the node's
#      podCIDR. If any differ, restarts kindnet so it reads the current node IPs.
#        docker exec <node> grep subnet /etc/cni/net.d/10-kindnet.conflist
#        kubectl get node <node> -o jsonpath='{.spec.podCIDR}'
#        kubectl -n kube-system rollout restart daemonset kindnet
#   2. Lists running pods whose IP is outside their node's podCIDR. None: done.
#   3. Asks y/N, then recreates them in this order (a new pod gets a new IP):
#      a. CoreDNS, so names resolve first.
#           kubectl -n kube-system delete pod -l k8s-app=kube-dns
#      b. All other affected pods except databases, openbao and kube-system.
#      c. All affected PostgreSQL pods together, then waits up to 10 min for 3
#         ready instances. One at a time deadlocks: the CloudNativePG operator does
#         not recreate a deleted instance while it cannot reach the others. After
#         4 min it prints the force-delete command for a pod stuck in Terminating
#         (it does not run it).
#      d. The OpenBao pods.
#           kubectl -n openbao delete pod -l app.kubernetes.io/name=openbao,component=server --wait=false
#   4. Checks again for pods with a wrong IP.
#
# What you should see: one line per node with both ranges, then "none: pod
#   network is consistent", or after the fix "PostgreSQL healthy with 3
#   instances" and "all pods have IPs from their node's range".
# If it fails: a PostgreSQL pod stuck in Terminating: run the printed
#   --grace-period=0 --force command. Afterwards: scripts/after-restart/openbao-unseal.sh
#   and scripts/verify/test-gate.sh.
# Needs: kind, docker, kubectl, jq. Prints no secrets.
set -euo pipefail

CLUSTER=openbao-platform

# wrong_ip_pods: "namespace name" of running pods whose IP is outside the
# podCIDR (first three octets) of the node they run on
wrong_ip_pods() {
  local cidrs
  cidrs=$(kubectl get nodes -o json | jq '[.items[] | {(.metadata.name): (.spec.podCIDR | split(".")[0:3] | join("."))}] | add')
  kubectl get pods -A -o json | jq -r --argjson n "$cidrs" '.items[]
    | select(.spec.hostNetwork != true and .status.podIP != null and .status.phase == "Running")
    | select((.status.podIP | split(".")[0:3] | join(".")) != $n[.spec.nodeName])
    | "\(.metadata.namespace) \(.metadata.name)"'
}

echo "==> 1. kindnet pod range per node"
MISMATCH=no
for node in $(kind get nodes --name "$CLUSTER"); do
  want=$(kubectl get node "$node" -o jsonpath='{.spec.podCIDR}')
  have=$(docker exec "$node" grep -o '"subnet": *"[^"]*"' /etc/cni/net.d/10-kindnet.conflist | grep -o '[0-9./]*/[0-9]*' || true)
  echo "$node: kindnet hands out ${have:-?}, node range $want"
  [[ "$have" == "$want" ]] || MISMATCH=yes
done
if [[ "$MISMATCH" == yes ]]; then
  echo "==> kindnet uses wrong ranges: restarting it"
  kubectl -n kube-system rollout restart daemonset kindnet
  kubectl -n kube-system rollout status daemonset kindnet --timeout=180s
fi

echo
echo "==> 2. Pods with an IP outside their node's range"
mapfile -t WRONG < <(wrong_ip_pods)
if (( ${#WRONG[@]} == 0 )); then echo "none: pod network is consistent"; exit 0; fi
printf '  %s\n' "${WRONG[@]}"
read -r -p "Recreate these ${#WRONG[@]} pods (PostgreSQL one at a time, OpenBao comes back sealed)? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted, nothing changed"; exit 1; }

echo
echo "==> 3a. CoreDNS"
kubectl -n kube-system delete pod -l k8s-app=kube-dns
kubectl -n kube-system rollout status deployment coredns --timeout=180s

echo
echo "==> 3b. Other affected pods (not databases, not openbao)"
for entry in "${WRONG[@]}"; do
  read -r ns pod <<<"$entry"
  [[ "$ns" == databases || "$ns" == openbao || "$ns" == kube-system ]] && continue
  kubectl -n "$ns" delete pod "$pod" --wait=false
done
sleep 20

echo
echo "==> 3c. PostgreSQL (affected pods together)"
for entry in "${WRONG[@]}"; do
  read -r ns pod <<<"$entry"
  [[ "$ns" == databases ]] && kubectl -n databases delete pod "$pod" --wait=false
done
HEALTHY=no
for i in $(seq 60); do   # up to 10 minutes
  if [[ "$(kubectl -n databases get cluster pg-openbao -o jsonpath='{.status.readyInstances}')" == 3 ]] &&
     kubectl -n databases get cluster pg-openbao -o jsonpath='{.status.phase}' | grep -q healthy; then
    HEALTHY=yes; break
  fi
  if (( i == 24 )); then   # after 4 minutes
    STUCK=$(kubectl -n databases get pods --no-headers | awk '$3=="Terminating"{print $1}')
    [[ -n "$STUCK" ]] && echo "Still Terminating after 4 min: $STUCK. If it does not finish, force it (crash-style stop, data stays on the volume):" &&
      for p in $STUCK; do echo "  kubectl -n databases delete pod $p --grace-period=0 --force"; done
  fi
  sleep 10
done
kubectl -n databases get pods -L cnpg.io/instanceRole
[[ "$HEALTHY" == yes ]] && echo "PostgreSQL healthy with 3 instances" || echo "PostgreSQL NOT healthy after 10 min: check the pods above"

echo
echo "==> 3d. OpenBao"
kubectl -n openbao delete pod -l app.kubernetes.io/name=openbao,component=server --wait=false
sleep 20
kubectl -n openbao get pods -o wide

echo
echo "==> 4. Check"
LEFT=$(wrong_ip_pods)
[[ -z "$LEFT" ]] && echo "all pods have IPs from their node's range" || { echo "still wrong:"; echo "$LEFT"; }
echo
echo "Next: bash scripts/after-restart/openbao-unseal.sh, then bash scripts/verify/test-gate.sh"
