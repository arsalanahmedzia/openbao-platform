#!/usr/bin/env bash
# External Secrets stage, step 4: after `git push`, lets Flux apply the new
# layer apps-external-secrets and shows whether the ClusterSecretStore
# "openbao" could log in to OpenBao (status Valid, condition Ready).
# Prints no secrets.
#   bash scripts/external-secrets/eso-store-check.sh
set -euo pipefail

echo "==> Flux: fetch Git and apply apps-external-secrets"
flux reconcile source git flux-system
flux reconcile kustomization apps-external-secrets

echo
echo "==> ClusterSecretStore"
kubectl wait clustersecretstore/openbao --for=condition=Ready --timeout=120s || true
kubectl get clustersecretstore openbao
echo
kubectl get clustersecretstore openbao \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} message={.message}{"\n"}{end}'

echo
echo "==> Namespace and demo-writer service account"
kubectl -n eso-demo get serviceaccount demo-writer

echo
echo "==> Flux layers"
flux get kustomizations
