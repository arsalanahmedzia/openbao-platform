#!/usr/bin/env bash
# Hardening B2b: after `git push`, applies the NetworkPolicies of namespace
# databases and proves them:
#   open:    OpenBao-labelled pod in openbao -> pg-openbao-rw:5432
#   blocked: unlabelled pod in openbao       -> pg-openbao-rw:5432
#   blocked: pod in default -> 5432, and -> instance manager :8000
#   real:    kubectl cnpg status (API server -> :8000), streaming replication,
#            a base backup (operator -> :8000), OpenBao still active
# Probe pods are temporary (kubectl run --rm), deleted right after use.
#   bash scripts/netpol-test-databases.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=busybox:1.37.0
NODE_CIDR_PREFIX=172.18.   # must match the ipBlock in apps/database/networkpolicy.yaml

echo "==> Node IPs must be inside 172.18.0.0/16 (ipBlock for the API server)"
kubectl get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[0].address}'); do
  [[ "$ip" == "$NODE_CIDR_PREFIX"* ]] || { echo "node IP $ip is outside 172.18.0.0/16: fix the ipBlock first"; exit 1; }
done

echo
echo "==> Flux: apply apps-database"
flux reconcile source git flux-system
flux reconcile kustomization apps-database
kubectl -n databases get networkpolicy

# probe <namespace> <labels or -> <host> <port> <expected: open|blocked>
FAILS=0
probe() {
  local ns=$1 labels=$2 host=$3 port=$4 expected=$5 got args=()
  [[ "$labels" != - ]] && args=(--labels="$labels")
  if kubectl -n "$ns" run "netpol-probe-$RANDOM" --image="$IMAGE" --restart=Never --rm -i --quiet "${args[@]}" \
       --command -- nc -w 3 "$host" "$port" </dev/null >/dev/null 2>&1; then got=open; else got=blocked; fi
  local who="$ns${labels/#-/}"; [[ "$labels" != - ]] && who="$ns ($labels)"
  if [[ "$got" == "$expected" ]]; then echo "PASS  $who -> $host:$port expected $expected, got $got"
  else echo "FAIL  $who -> $host:$port expected $expected, got $got"; FAILS=$((FAILS + 1)); fi
}

PRIMARY_IP=$(kubectl -n databases get pods -l cnpg.io/cluster=pg-openbao,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].status.podIP}')
echo
echo "==> Connectivity (primary pod IP $PRIMARY_IP)"
probe openbao app.kubernetes.io/name=openbao pg-openbao-rw.databases.svc 5432 open
probe openbao - pg-openbao-rw.databases.svc 5432 blocked
probe default - pg-openbao-rw.databases.svc 5432 blocked
probe default - "$PRIMARY_IP" 8000 blocked

echo
echo "==> Real paths"
echo "--- kubectl cnpg status (API server -> instance manager :8000) and replication"
kubectl cnpg status pg-openbao -n databases |
  sed -n -e '/^Status:/p' -e '/^Ready instances:/p' -e '/Streaming Replication status/,/^$/p' -e '/Instances status/,/^$/p'
echo "--- base backup (operator -> instance manager :8000, plugin -> S3)"
bash scripts/pg-backup-check.sh | sed -n '/Manual base backup/,$p'
echo "--- OpenBao (uses PostgreSQL)"
kubectl -n openbao get pods -L openbao-active,openbao-sealed

echo
(( FAILS == 0 )) && echo "RESULT: databases policies work as intended" || { echo "RESULT: $FAILS check(s) failed"; exit 1; }
