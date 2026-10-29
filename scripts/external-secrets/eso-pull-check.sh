#!/usr/bin/env bash
# eso-pull-check.sh - applies the ExternalSecret and shows the Kubernetes Secret ESO created from OpenBao.
# Run it: bash scripts/external-secrets/eso-pull-check.sh (after git push of the ExternalSecret)
# Changes the cluster: no. It asks Flux to apply what is in Git now; then it
#   only reads. The value hello-from-openbao is a demo value, so it is shown.
#
# What it does:
#   1. Applies Git now.
#        flux reconcile kustomization apps-external-secrets
#   2. Waits up to 60 s until the ExternalSecret eso-demo/hello is Ready.
#        kubectl -n eso-demo wait externalsecret/hello --for=condition=Ready --timeout=60s
#   3. Shows the Secret hello-from-openbao: its owner, its keys, the decoded value.
#        kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.data.message}' | base64 -d
#
# What you should see: "owner: ExternalSecret/hello", keys ["message"],
#   "message (decoded): hello-from-openbao".
# If it fails: the wait times out: bash scripts/external-secrets/eso-debug.sh externalsecret hello
# Needs: flux, kubectl, jq.
set -euo pipefail

NS=eso-demo

echo "==> Flux: fetch Git and apply apps-external-secrets"
flux reconcile source git flux-system
flux reconcile kustomization apps-external-secrets

echo
echo "==> ExternalSecret"
kubectl -n "$NS" wait externalsecret/hello --for=condition=Ready --timeout=60s
kubectl -n "$NS" get externalsecret hello

echo
echo "==> Kubernetes Secret created by ESO"
kubectl -n "$NS" get secret hello-from-openbao
echo "owner: $(kubectl -n "$NS" get secret hello-from-openbao -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}')"
echo "keys:  $(kubectl -n "$NS" get secret hello-from-openbao -o jsonpath='{.data}' | jq -c 'keys')"
echo "message (decoded): $(kubectl -n "$NS" get secret hello-from-openbao -o jsonpath='{.data.message}' | base64 -d)"
