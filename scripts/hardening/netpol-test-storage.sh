#!/usr/bin/env bash
# Hardening B2a: after `git push`, applies the NetworkPolicies of namespace
# storage and proves them:
#   allowed: namespace databases -> seaweedfs:8333 (any HTTP answer = connected;
#            S3 answers 403 without credentials)
#   blocked: namespace default   -> seaweedfs:8333 (must time out)
#   real:    a PostgreSQL base backup through the Barman plugin completes
# The probe pods are temporary (kubectl run --rm), deleted right after use.
#   bash scripts/hardening/netpol-test-storage.sh
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
bash scripts/pg-backup-check.sh | sed -n '/Manual base backup/,$p'

echo
(( FAILS == 0 )) && echo "RESULT: storage policies work as intended" || { echo "RESULT: $FAILS check(s) failed"; exit 1; }
