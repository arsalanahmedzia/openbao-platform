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
#      c. all affected PostgreSQL pods TOGETHER (data stays on the volumes).
#         Not one at a time: the CloudNativePG operator does not recreate a
#         deleted instance while it cannot reach the others (wrong IPs), which
#         deadlocked the first version of this script. A primary with a wrong
#         IP can hang in Terminating while it tries to archive WAL to S3; the
#         script then prints the force-delete command (it does not run it).
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
echo "Next: bash scripts/openbao-unseal.sh, then bash scripts/test-gate.sh"
