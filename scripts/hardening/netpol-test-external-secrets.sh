#!/usr/bin/env bash
# netpol-test-external-secrets.sh - applies and proves the NetworkPolicies of namespace external-secrets (hardening B2d).
# Run it: bash scripts/hardening/netpol-test-external-secrets.sh (after git push of infrastructure/controllers/external-secrets-networkpolicy.yaml)
# Changes the cluster: yes: starts temporary probe pods (kubectl run --rm).
#   The dry-run creates save nothing.
#
# What it does:
#   1. Applies Git now.
#        flux reconcile kustomization infra-controllers
#   2. Real path: a server-side dry run of renamed copies of the ExternalSecret
#      and the ClusterSecretStore runs ESO's validating webhooks (failurePolicy
#      Fail) without saving anything; it succeeds only if the API server reaches
#      the webhook.
#        sed "0,/^  name: /s//  name: netpol-dryrun-/" <file> | kubectl create --dry-run=server -f -
#   3. Probes from namespace default with temporary pods (must be blocked):
#      webhook pod :10250 and controller metrics :8080.
#   4. Real paths: ESO pods, the store still Valid, Flux still reconciles
#      apps-external-secrets.
#        flux reconcile kustomization apps-external-secrets
#
# What you should see: "PASS webhook reached for ..." twice, two blocked
#   probes, then "RESULT: external-secrets policies work as intended".
# If it fails: "webhook not reached": the API server cannot reach port 10250;
#   then every change to ESO objects fails (failurePolicy Fail).
# Needs: flux, kubectl, sed, the image busybox:1.37.0.
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE=busybox:1.37.0
NS=external-secrets

echo "==> Flux: apply infra-controllers"
flux reconcile source git flux-system
flux reconcile kustomization infra-controllers
kubectl -n "$NS" get networkpolicy

FAILS=0
# probe <ip> <port> <expected: open|blocked> from namespace default
probe() {
  local ip=$1 port=$2 expected=$3 got
  if kubectl -n default run "netpol-probe-$RANDOM" --image="$IMAGE" --restart=Never --rm -i --quiet \
       --command -- nc -w 3 "$ip" "$port" </dev/null >/dev/null 2>&1; then got=open; else got=blocked; fi
  if [[ "$got" == "$expected" ]]; then echo "PASS  default -> $ip:$port expected $expected, got $got"
  else echo "FAIL  default -> $ip:$port expected $expected, got $got"; FAILS=$((FAILS + 1)); fi
}

echo
echo "==> API server -> ESO webhook (server-side dry run of a renamed copy: nothing is saved,"
echo "    the live objects owned by Flux are not touched)"
for f in apps/external-secrets/externalsecret-hello.yaml apps/external-secrets/clustersecretstore.yaml; do
  if sed "0,/^  name: /s//  name: netpol-dryrun-/" "$f" | kubectl create --dry-run=server -f -; then echo "PASS  webhook reached for $f"
  else echo "FAIL  webhook not reached for $f"; FAILS=$((FAILS + 1)); fi
done

WEBHOOK_IP=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=external-secrets-webhook -o jsonpath='{.items[0].status.podIP}')
CONTROLLER_IP=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=external-secrets -o jsonpath='{.items[0].status.podIP}')
echo
echo "==> Connectivity from namespace default (temporary probe pods)"
probe "$WEBHOOK_IP" 10250 blocked
probe "$CONTROLLER_IP" 8080 blocked

echo
echo "==> Real paths: ESO pods, store, Flux layer"
kubectl -n "$NS" get pods
kubectl get clustersecretstore openbao
flux reconcile kustomization apps-external-secrets

echo
(( FAILS == 0 )) && echo "RESULT: external-secrets policies work as intended" || { echo "RESULT: $FAILS check(s) failed"; exit 1; }
