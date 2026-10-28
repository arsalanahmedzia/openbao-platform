#!/usr/bin/env bash
# Repairs the kind pod network after Docker gave the node containers different
# IP addresses on a restart (seen 2026-10-28: every pod got an IP from another
# node's range, DNS timed out, OpenBao crashed because it could not resolve
# pg-openbao-rw).
#
# What it does:
#   1. For each node, compares the pod range kindnet hands out
#      (/etc/cni/net.d/10-kindnet.conflist) with the node's podCIDR.
#        docker exec <node> grep subnet /etc/cni/net.d/10-kindnet.conflist
#        kubectl get nodes -o custom-columns=...PODCIDR:.spec.podCIDR
#      If any differ: restarts kindnet so it reads the current node IPs.
#        kubectl -n kube-system rollout restart daemonset kindnet
#   2. Lists pods whose IP is outside their node's podCIDR. None: done.
#   3. Asks y/N, then recreates them in a safe order (a new pod gets a new IP):
#      a. CoreDNS (names must resolve first)
#      b. all other affected pods except databases and openbao
#      c. PostgreSQL pods one at a time: replicas first, then the primary
#         (short failover); data stays on the volumes
#      d. the OpenBao pods (they come back SEALED)
#        kubectl -n <ns> delete pod <pod>
#   4. Reminds you to unseal and run the test gate.
# Prints no secrets.
#   bash scripts/kind-fix-pod-network.sh
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
echo "==> 3c. PostgreSQL, one pod at a time (replicas first)"
PRIMARY=$(kubectl -n databases get cluster pg-openbao -o jsonpath='{.status.currentPrimary}')
REPLICAS=$(kubectl -n databases get pods -l cnpg.io/cluster=pg-openbao,cnpg.io/instanceRole=replica -o jsonpath='{.items[*].metadata.name}')
for pod in $REPLICAS "$PRIMARY"; do
  printf '%s\n' "${WRONG[@]}" | grep -qx "databases $pod" || { echo "$pod: IP fine, skipped"; continue; }
  echo "--- $pod"
  kubectl -n databases delete pod "$pod"
  until kubectl -n databases get pod "$pod" >/dev/null 2>&1; do sleep 2; done
  kubectl -n databases wait pod "$pod" --for=condition=Ready --timeout=300s
done
kubectl -n databases get pods -L cnpg.io/instanceRole

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
echo "Next: bash scripts/openbao-unseal.sh, then bash scripts/test-gate.sh"
