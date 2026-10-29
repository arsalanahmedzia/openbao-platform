#!/usr/bin/env bash
# eso-push-check.sh - applies the PushSecret and reads the pushed value back from OpenBao as the ESO login.
#
# In plain words:
#   Push is the other direction: ESO copies a Kubernetes Secret into OpenBao.
#   The PushSecret eso-demo/push-demo copies the Secret eso-demo/push-demo to
#   secret/pushed/push-demo.
#
#   This script asks Flux to apply it now, waits until the PushSecret is
#   Ready, and then checks the result from the OpenBao side: it logs in as the
#   ESO service account (no root) and reads the pushed value and its metadata
#   back. The marker managed-by external-secrets shows that ESO owns the
#   value. The token is revoked at the end.
#
# Run it: bash scripts/external-secrets/eso-push-check.sh (after git push of the PushSecret)
# Changes the cluster: no. It asks Flux to apply what is in Git now, then logs
#   in as the ESO service account (no root) and revokes that token at the end.
#
# What it does:
#   1. Applies Git now and waits up to 60 s until the PushSecret is Ready.
#        flux reconcile kustomization apps-external-secrets
#        kubectl -n eso-demo wait pushsecret/push-demo --for=condition=Ready --timeout=60s
#   2. Shows the source Secret eso-demo/push-demo.
#   3. Logs in as the ESO service account and reads the value back.
#        kubectl -n external-secrets create token external-secrets --duration=10m
#        bao kv get -mount=secret -field=message pushed/push-demo
#        bao kv metadata get -mount=secret pushed/push-demo
#
# What you should see: the PushSecret Synced, "field message:
#   pushed-from-kubernetes" and custom_metadata with managed-by external-secrets.
# If it fails: bash scripts/external-secrets/eso-debug.sh pushsecret push-demo
# Needs: flux, kubectl. Demo value only; tokens go to the pod through stdin.
set -euo pipefail

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server

echo "==> Flux: fetch Git and apply apps-external-secrets"
flux reconcile source git flux-system
flux reconcile kustomization apps-external-secrets

echo
echo "==> PushSecret"
kubectl -n eso-demo wait pushsecret/push-demo --for=condition=Ready --timeout=60s
kubectl -n eso-demo get pushsecret push-demo
echo "source Secret eso-demo/push-demo, key message: $(kubectl -n eso-demo get secret push-demo -o jsonpath='{.data.message}' | base64 -d)"

POD=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}')
JWT=$(kubectl -n external-secrets create token external-secrets --duration=10m)
ESO_TOKEN=$(printf '%s' "$JWT" |
  kubectl -n "$NS" exec -i "$POD" -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-)
unset JWT
eso() {
  printf '%s\n' "$ESO_TOKEN" |
    kubectl -n "$NS" exec -i "$POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' sh "$@"
}

echo
echo "==> Read back from OpenBao as the ESO login"
echo "secret/pushed/push-demo, field message: $(eso kv get -mount=secret -field=message pushed/push-demo)"
eso kv metadata get -mount=secret pushed/push-demo | grep -E '^(current_version|custom_metadata) '
eso token revoke -self >/dev/null
unset ESO_TOKEN
