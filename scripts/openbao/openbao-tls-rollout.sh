#!/usr/bin/env bash
# openbao-tls-rollout.sh - applies a new OpenBao config and restarts only the outdated pods, one by one.
#
# In plain words:
#   OpenBao reads its configuration only when a pod starts. The chart is set
#   to OnDelete: when the configuration in Git changes, Kubernetes updates the
#   template, but running pods keep the old configuration until someone
#   deletes them. This script does that safely, one pod at a time.
#
#   It asks Flux to apply the change now, waits for the listener certificate,
#   then compares each pod with the newest template (the StatefulSet
#   revision). Only outdated pods are deleted: the two standbys first, the
#   active pod last, so there is always an active pod. Each new pod starts
#   sealed and the script unseals it before it moves on. At the end it checks
#   the TLS name ESO uses and HTTPS through Traefik. Pods that are already up
#   to date are skipped, so it is safe to run again.
#
# Run it: bash scripts/openbao/openbao-tls-rollout.sh (after git push of a change to the OpenBao config; safe to run again)
# Changes the cluster: yes: restarts OpenBao pods (they come back sealed) and
#   unseals each one. Pods already on the new StatefulSet revision are skipped.
#
# What it does:
#   1. Applies Git and waits for the listener certificate.
#        flux reconcile kustomization apps-openbao ; flux reconcile helmrelease openbao -n openbao
#        kubectl -n openbao wait certificate/openbao-server-tls --for=condition=Ready --timeout=120s
#   2. Reads the target StatefulSet revision. The chart uses updateStrategy
#      OnDelete: running pods keep the old config until they are deleted.
#        kubectl -n openbao get statefulset openbao -o jsonpath='{.status.updateRevision}'
#   3. Restarts every pod on an old revision, standbys first, the active pod
#      last, and unseals each new pod.
#        kubectl -n openbao delete pod <pod>
#        bash scripts/after-restart/openbao-unseal.sh
#   4. Checks TLS with the name ESO uses, and HTTPS through Traefik.
#        kubectl -n openbao exec <active pod> -- bao status -address=https://openbao-active.openbao.svc:8200
#        curl --resolve openbao.demo.local:443:127.0.0.1 --cacert <ca> https://openbao.demo.local/v1/sys/health
#
# What you should see: "target StatefulSet revision: ...", per pod "already on"
#   or "unsealed and Ready", one pod with HA Mode active, and
#   "GET https://openbao.demo.local/v1/sys/health -> HTTP 200".
# If it fails: a pod that does not come back: kubectl -n openbao describe pod <pod>.
#   This script does not restart pods after a certificate renewal (same
#   revision); see docs/runbooks/openbao-init-unseal.md, section 4.
# Needs: flux, kubectl, curl, the unseal keys (see openbao-unseal.sh).
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
  bash scripts/after-restart/openbao-unseal.sh >/dev/null
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
