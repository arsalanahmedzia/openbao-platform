#!/usr/bin/env bash
# Hardening B2e: after `git push`, applies the default-deny policy of namespace
# eso-demo and proves it with a TEMPORARY web server pod in eso-demo:
#   blocked: default -> server:8080, and eso-demo -> server:8080 (a default
#            deny also blocks traffic inside the namespace)
#   real:    the refresh test (ExternalSecret in eso-demo) still works
# The server pod is deleted at the end, also if the script fails; probe pods
# are temporary (kubectl run --rm).
#   bash scripts/hardening/netpol-test-eso-demo.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE=busybox:1.37.0
NS=eso-demo
trap 'kubectl -n "$NS" delete pod netpol-server --ignore-not-found --wait=false >/dev/null' EXIT

echo "==> Flux: apply apps-external-secrets"
flux reconcile source git flux-system
flux reconcile kustomization apps-external-secrets
kubectl -n "$NS" get networkpolicy

echo
echo "==> Temporary web server pod in $NS"
kubectl -n "$NS" run netpol-server --image="$IMAGE" --restart=Never \
  --command -- sh -c 'echo ok > /tmp/index.html && exec httpd -f -p 8080 -h /tmp'
kubectl -n "$NS" wait pod netpol-server --for=condition=Ready --timeout=60s
SERVER_IP=$(kubectl -n "$NS" get pod netpol-server -o jsonpath='{.status.podIP}')

FAILS=0
# probe <from namespace> <expected: open|blocked>
probe() {
  local ns=$1 expected=$2 got
  if kubectl -n "$ns" run "netpol-probe-$RANDOM" --image="$IMAGE" --restart=Never --rm -i --quiet \
       --command -- nc -w 3 "$SERVER_IP" 8080 </dev/null >/dev/null 2>&1; then got=open; else got=blocked; fi
  if [[ "$got" == "$expected" ]]; then echo "PASS  $ns -> $NS/netpol-server:8080 expected $expected, got $got"
  else echo "FAIL  $ns -> $NS/netpol-server:8080 expected $expected, got $got"; FAILS=$((FAILS + 1)); fi
}

echo
echo "==> Connectivity (server $SERVER_IP)"
probe default blocked
probe "$NS" blocked

echo
echo "==> Real path: ExternalSecret refresh in $NS"
bash scripts/external-secrets/eso-refresh-test.sh

echo
(( FAILS == 0 )) && echo "RESULT: eso-demo policy works as intended" || { echo "RESULT: $FAILS check(s) failed"; exit 1; }
