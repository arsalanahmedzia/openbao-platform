#!/usr/bin/env bash
# External Secrets stage, step 8: collects the evidence for the stage into
# docs/evidence/05-external-secrets.txt (also shown on screen):
#   Flux layers, store status, pull (value), refresh test, push (read back as
#   the ESO login), least privilege of the ESO login.
# Demo values only (hello-from-openbao, pushed-from-kubernetes). Tokens stay in
# variables and go to the pod via stdin; the file is scanned for tokens at the end.
#   bash scripts/external-secrets/eso-evidence.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=docs/evidence/05-external-secrets.txt
NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server

# After a git push Flux rolls the new revision through the layers one by one
# (dependsOn); capture only once every layer has applied it and is Ready.
echo "==> Waiting for all Flux layers to be Ready (up to 10 min)"
flux reconcile source git flux-system
kubectl -n flux-system wait kustomization --all --for=condition=Ready --timeout=10m

{
echo "# External Secrets stage: evidence, captured $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# Command: bash scripts/external-secrets/eso-evidence.sh"

echo
echo "==> 1. Flux layers"
flux get kustomizations

echo
echo "==> 2. ClusterSecretStore openbao (HTTPS, demo CA, Kubernetes auth)"
kubectl get clustersecretstore openbao
kubectl get clustersecretstore openbao \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} message={.message}{"\n"}{end}'

echo
echo "==> 3. Pull: ExternalSecret eso-demo/hello -> Secret hello-from-openbao"
kubectl -n eso-demo get externalsecret hello
echo "owner: $(kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}')"
echo "message (decoded): $(kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.data.message}' | base64 -d)"

echo
echo "==> 4. Refresh: change in OpenBao (as eso-demo/demo-writer) reaches Kubernetes"
bash scripts/external-secrets/eso-refresh-test.sh

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
echo "==> 5. Push: PushSecret eso-demo/push-demo -> secret/pushed/push-demo"
kubectl -n eso-demo get pushsecret push-demo
echo "read back as the ESO login, field message: $(eso kv get -mount=secret -field=message pushed/push-demo)"
eso kv metadata get -mount=secret pushed/push-demo | grep -E '^(current_version|custom_metadata) '

echo
echo "==> 6. Least privilege of the ESO login (role external-secrets)"
echo "token policies: $(eso token lookup -format=json | jq -c '.data.policies')"
echo "read  secret/demo/hello:      $(eso kv get -mount=secret -field=message demo/hello) (allowed, expected)"
eso kv put -mount=secret pushed/lp-check ok=true >/dev/null && echo "write secret/pushed/lp-check:  allowed (expected)"
eso kv metadata delete -mount=secret pushed/lp-check >/dev/null && echo "delete secret/pushed/lp-check: allowed (expected)"
for path in demo/denied other/denied; do
  if eso kv put -mount=secret "$path" ok=true >/dev/null 2>&1; then
    echo "write secret/$path: ALLOWED - policy is too wide!"; exit 1
  else
    echo "write secret/$path: denied (expected)"
  fi
done
eso token revoke -self >/dev/null
unset ESO_TOKEN
} 2>&1 | tee "$OUT"

echo
echo "==> Token scan of $OUT (expect: nothing found)"
grep -nE '\b(s|hvs|hvb|hvr)\.[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{20,}' "$OUT" || echo "nothing found"
