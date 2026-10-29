#!/usr/bin/env bash
# eso-debug.sh - shows why an External Secrets object is not Ready.
# Run it: bash scripts/external-secrets/eso-debug.sh                     (default: pushsecret push-demo)
#         bash scripts/external-secrets/eso-debug.sh externalsecret hello
# Changes the cluster: no. ESO logs paths and errors, not secret values.
#
# What it does:
#   1. Shows the object's conditions in namespace eso-demo.
#        kubectl -n eso-demo get <kind> <name> -o jsonpath='{range .status.conditions[*]}...'
#   2. Shows its events.
#        kubectl -n eso-demo get events --field-selector involvedObject.name=<name>
#   3. Shows the store status.
#        kubectl get clustersecretstore openbao
#   4. Shows the last 10 lines of the ESO controller log that name the object.
#        kubectl -n external-secrets logs deploy/external-secrets --tail=300 | grep -i <name>
#
# What you should see: Ready=True when all is fine; otherwise the reason and
#   message of the condition and the matching error lines.
# If it fails: "NotFound": check the kind and the name. What the messages mean:
#   docs/runbooks/external-secrets.md, section 2.
# Needs: kubectl.
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
