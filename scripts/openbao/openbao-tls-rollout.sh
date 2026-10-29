#!/usr/bin/env bash
# External Secrets stage, step 2: OpenBao listener switches to HTTPS.
# After `git push`: lets Flux apply the change, waits for the listener
# certificate, then restarts the OpenBao pods one at a time (standbys first,
# the active pod last; the chart uses updateStrategy OnDelete) and unseals
# each new pod. Only pods still on the old StatefulSet revision are restarted,
# so the script is safe to run again. Prints no keys or tokens.
#   bash scripts/openbao/openbao-tls-rollout.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server

echo "==> Flux: apply apps-openbao (certificate, ServersTransport, HelmRelease)"
flux reconcile source git flux-system
flux reconcile kustomization apps-openbao
flux reconcile helmrelease openbao -n "$NS"
kubectl -n "$NS" wait certificate/openbao-server-tls --for=condition=Ready --timeout=120s

NEW_REV=$(kubectl -n "$NS" get statefulset openbao -o jsonpath='{.status.updateRevision}')
echo "target StatefulSet revision: $NEW_REV"

# restart <pod>: delete it, wait for the new pod, unseal it.
restart() {
  local pod=$1
  if [[ "$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.metadata.labels.controller-revision-hash}')" == "$NEW_REV" ]]; then
    echo "--- $pod already on $NEW_REV"; return
  fi
  echo "--- restarting $pod"
  kubectl -n "$NS" delete pod "$pod"
  until kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; do sleep 2; done
  kubectl -n "$NS" wait pod "$pod" --for=jsonpath='{.status.phase}'=Running --timeout=180s
  sleep 5   # let OpenBao start its listener before unsealing
  bash scripts/openbao-unseal.sh >/dev/null
  echo "$pod: unsealed and Ready"
}

echo
echo "==> Rolling restart: standbys first, then the active pod"
for pod in $(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=false" -o jsonpath='{.items[*].metadata.name}'); do
  restart "$pod"
done
for pod in $(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[*].metadata.name}'); do
  restart "$pod"
done

echo
echo "==> Result"
kubectl -n "$NS" get pods -o wide -L openbao-active,openbao-sealed
echo "Service openbao-active port name: $(kubectl -n "$NS" get svc openbao-active -o jsonpath='{.spec.ports[0].name}')"
POD=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=true" -o jsonpath='{.items[0].metadata.name}')
echo
echo "==> TLS check inside the cluster: the name ESO will use, verified with the demo CA"
kubectl -n "$NS" exec "$POD" -- bao status -address=https://openbao-active.openbao.svc:8200 |
  grep -E '^(Sealed|HA Enabled|HA Mode)'
echo
echo "==> HTTPS through Traefik (now Traefik -> OpenBao is HTTPS too)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
kubectl -n "$NS" get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"
curl -sS --resolve openbao.demo.local:443:127.0.0.1 --cacert "$TMP/ca.crt" \
  -o /dev/null -w 'GET https://openbao.demo.local/v1/sys/health -> HTTP %{http_code}\n' \
  https://openbao.demo.local/v1/sys/health
