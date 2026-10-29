#!/usr/bin/env bash
# netpol-test-storage.sh - applies and proves the NetworkPolicies of namespace storage (hardening B2a).
# Run it: bash scripts/hardening/netpol-test-storage.sh (after git push of infrastructure/storage/networkpolicy.yaml)
# Changes the cluster: yes: starts temporary probe pods (kubectl run --rm,
#   deleted right after use) and takes one base backup (pg-backup-check.sh).
#
# What it does:
#   1. Applies Git now.
#        flux reconcile kustomization infra-storage
#   2. Probes the S3 port 8333 with wget from temporary pods: any HTTP answer
#      means connected (S3 answers 403 without credentials).
#        allowed: namespace databases -> seaweedfs:8333
#        blocked: namespace default   -> seaweedfs:8333 (must time out)
#        kubectl -n <ns> run netpol-probe-<n> --image=busybox:1.37.0 --rm -i -- wget -S -T 3 -O /dev/null http://seaweedfs.storage.svc.cluster.local:8333/
#   3. Shows SeaweedFS still Ready (kubelet probes are not blocked).
#   4. Real path: a PostgreSQL base backup through the Barman plugin completes.
#        bash scripts/database/pg-backup-check.sh
#
# What you should see: "expected open, got open", "expected blocked, got
#   blocked", the backup with phase=completed, then
#   "RESULT: storage policies work as intended".
# If it fails: the backup fails: the rule from databases to storage is missing.
# Needs: flux, kubectl with the cnpg plugin, jq, the image busybox:1.37.0.
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE=busybox:1.37.0
URL=http://seaweedfs.storage.svc.cluster.local:8333/

echo "==> Flux: apply infra-storage"
flux reconcile source git flux-system
flux reconcile kustomization infra-storage
kubectl -n storage get networkpolicy

# probe <namespace> <expected: open|blocked>
FAILS=0
probe() {
  local ns=$1 expected=$2 out got
  out=$(kubectl -n "$ns" run "netpol-probe-$RANDOM" --image="$IMAGE" --restart=Never --rm -i --quiet \
        --command -- wget -S -T 3 -O /dev/null "$URL" 2>&1 || true)
  if grep -q 'HTTP/' <<<"$out"; then got=open; else got=blocked; fi
  if [[ "$got" == "$expected" ]]; then echo "PASS  $ns -> seaweedfs:8333 expected $expected, got $got ($(grep -m1 -oE 'HTTP/[0-9.]+ [0-9]+' <<<"$out" || echo timeout))"
  else echo "FAIL  $ns -> seaweedfs:8333 expected $expected, got $got"; FAILS=$((FAILS + 1)); fi
}

echo
echo "==> Connectivity"
probe databases open
probe default blocked

echo
echo "==> SeaweedFS still Ready (kubelet probes not blocked)"
kubectl -n storage get pods -l app.kubernetes.io/name=seaweedfs

echo
echo "==> Real path: base backup through the Barman plugin"
bash scripts/database/pg-backup-check.sh | sed -n '/Manual base backup/,$p'

echo
(( FAILS == 0 )) && echo "RESULT: storage policies work as intended" || { echo "RESULT: $FAILS check(s) failed"; exit 1; }
