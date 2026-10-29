#!/usr/bin/env bash
# External Secrets stage, step 7: after `git push`, applies the PushSecret
# eso-demo/push-demo and reads the pushed value back from OpenBao AS THE ESO
# LOGIN (Kubernetes auth, role external-secrets; no root). Demo value only;
# tokens stay in variables and go to the pod via stdin.
#   bash scripts/external-secrets/eso-push-check.sh
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
