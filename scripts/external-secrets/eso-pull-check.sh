#!/usr/bin/env bash
# External Secrets stage, step 5: after `git push`, applies the ExternalSecret
# eso-demo/hello and shows that ESO created the Kubernetes Secret
# hello-from-openbao with the value from secret/demo/hello in OpenBao.
# The value hello-from-openbao is a demo value, not a secret, so it is shown.
#   bash scripts/external-secrets/eso-pull-check.sh
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
