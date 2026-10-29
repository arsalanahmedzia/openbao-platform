#!/usr/bin/env bash
# Shows why an External Secrets object is not Ready: its status conditions,
# its events and the matching lines of the ESO controller log.
# ESO logs paths and errors, not secret values. Changes nothing.
#   bash scripts/external-secrets/eso-debug.sh                          (default: pushsecret push-demo)
#   bash scripts/external-secrets/eso-debug.sh externalsecret hello
set -euo pipefail

KIND=${1:-pushsecret}
NAME=${2:-push-demo}
NS=eso-demo

echo "==> $KIND $NS/$NAME: conditions"
kubectl -n "$NS" get "$KIND" "$NAME" \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} message={.message}{"\n"}{end}'

echo
echo "==> Events"
kubectl -n "$NS" get events --field-selector "involvedObject.name=$NAME" \
  --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,TYPE:.type,REASON:.reason,MESSAGE:.message

echo
echo "==> ClusterSecretStore openbao"
kubectl get clustersecretstore openbao

echo
echo "==> ESO controller log, last lines mentioning $NAME"
kubectl -n external-secrets logs deploy/external-secrets --tail=300 | grep -i "$NAME" | tail -10 || true
