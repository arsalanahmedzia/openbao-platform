#!/usr/bin/env bash
# eso-evidence.sh - collects the External Secrets evidence into docs/evidence/05-external-secrets.txt.
#
# This script records everything the External Secrets stage proved, in one
# file, docs/evidence/05-external-secrets.txt, and on the screen. It shows
# the Flux layers, the store status, the pulled value, a full refresh test
# (the value is changed in OpenBao and changed back), and the pushed value
# read back from OpenBao.
#
# Last, it checks least privilege: the ESO login may read secret/ and write
# only below secret/pushed/, and it must be refused on other paths. A login
# that may do more than it should stops the script. At the end it scans the
# file for anything that looks like a token.
#
# Run it: bash scripts/external-secrets/eso-evidence.sh (after the ESO stage; prints the same on screen)
# Changes the cluster: yes: runs the refresh test (demo value changed and
#   restored) and writes then deletes secret/pushed/lp-check.
#
# What it does:
#   1. Waits up to 10 min for all Flux layers.
#        kubectl -n flux-system wait kustomization --all --for=condition=Ready --timeout=10m
#   2. Records the store status and the pulled value.
#        kubectl get clustersecretstore openbao
#   3. Runs the refresh test.
#        bash scripts/external-secrets/eso-refresh-test.sh
#   4. Logs in as the ESO service account and reads the pushed value back.
#        bao kv get -mount=secret -field=message pushed/push-demo
#   5. Checks least privilege: the login may read secret/, write and delete only
#      below secret/pushed/, and is denied on secret/demo/denied and secret/other/denied.
#   6. Scans the file for tokens.
#        grep -nE '\b(s|hvs|hvb|hvr)\.[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{20,}' docs/evidence/05-external-secrets.txt
#
# What you should see: sections 1 to 6, "token policies:
#   ["default","eso-read","eso-write"]", each "(allowed, expected)" or
#   "denied (expected)", and "nothing found" from the token scan.
# If it fails: "ALLOWED - policy is too wide!" stops the script; fix the policy
#   in openbao/policies/ and run scripts/openbao/openbao-policy-update.sh.
# Needs: flux, kubectl, jq. Demo values only.
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
