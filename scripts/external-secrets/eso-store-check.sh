#!/usr/bin/env bash
# eso-store-check.sh - applies the External Secrets layer and shows whether the store can log in to OpenBao.
#
# In plain words:
#   The ClusterSecretStore openbao tells External Secrets (ESO) where OpenBao
#   is, which certificate to trust and how to log in. Before any secret can
#   move, ESO must be able to use this store. This script asks Flux to apply
#   the External Secrets layer now and then shows whether ESO could log in to
#   OpenBao with it.
#
#   "Valid" and Ready True mean the address, the certificate and the login all
#   work. Otherwise the condition message says which of the three failed. The
#   script only reads after the Flux step and prints no secrets.
#
# Run it: bash scripts/external-secrets/eso-store-check.sh (after git push of apps/external-secrets)
# Changes the cluster: no. It asks Flux to apply what is in Git now; then it
#   only reads. Prints no secrets.
#
# What it does:
#   1. Applies Git now.
#        flux reconcile source git flux-system
#        flux reconcile kustomization apps-external-secrets
#   2. Waits up to 120 s for the ClusterSecretStore and shows its conditions.
#        kubectl wait clustersecretstore/openbao --for=condition=Ready --timeout=120s
#   3. Shows the demo-writer service account and the Flux layers.
#        kubectl -n eso-demo get serviceaccount demo-writer
#
# What you should see: STATUS Valid, READY True, message "store validated".
# If it fails: the condition message names the cause; the table in
#   docs/runbooks/external-secrets.md, section 1, lists the usual ones.
# Needs: flux, kubectl.
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
