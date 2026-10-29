#!/usr/bin/env bash
# netpol-test-eso-demo.sh - applies and proves the default-deny policy of namespace eso-demo (hardening B2e).
#
# Namespace eso-demo has no pods, only Secrets and ESO objects, so it gets a
# default-deny rule and no allow rule: any pod added there later starts
# closed. To prove the rule, this script starts a temporary web server pod
# in eso-demo.
#
# Short-lived test pods from default and even from eso-demo itself must be
# blocked, because a default-deny also blocks traffic inside the namespace.
# As real proof it runs the refresh test: ESO writes the Secrets through the
# Kubernetes API, not into a pod, so syncing must still work. The server pod
# is deleted at the end, also if the script fails.
#
# Run it: bash scripts/hardening/netpol-test-eso-demo.sh (after git push of apps/external-secrets/networkpolicy.yaml)
# Changes the cluster: yes: starts a TEMPORARY web server pod in eso-demo
#   (deleted at the end, also if the script fails), temporary probe pods
#   (kubectl run --rm), and runs the refresh test (demo value changed and restored).
#
# What it does:
#   1. Applies Git now.
#        flux reconcile kustomization apps-external-secrets
#   2. Starts the temporary server pod netpol-server on port 8080.
#        kubectl -n eso-demo run netpol-server --image=busybox:1.37.0 --restart=Never --command -- sh -c '... httpd -f -p 8080 -h /tmp'
#   3. Probes it (both must be blocked; a default deny also blocks traffic
#      inside the namespace): from default, and from eso-demo.
#   4. Real path: the ExternalSecret refresh in eso-demo still works.
#        bash scripts/external-secrets/eso-refresh-test.sh
#
# What you should see: two "expected blocked, got blocked" lines, the refresh
#   test output, then "RESULT: eso-demo policy works as intended".
# If it fails: the refresh test fails: ESO writes Secrets through the Kubernetes
#   API, not into pods, so the policy itself is not the cause; see
#   scripts/external-secrets/eso-debug.sh.
# Needs: flux, kubectl, the image busybox:1.37.0.
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
