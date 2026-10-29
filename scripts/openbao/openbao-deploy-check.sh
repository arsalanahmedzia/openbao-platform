#!/usr/bin/env bash
# openbao-deploy-check.sh - applies the OpenBao layer and shows that the 3 pods run, sealed.
#
# After you push the OpenBao layer, Flux would apply it within about a
# minute on its own. This script asks Flux to apply it now (a reconcile) and
# then shows whether OpenBao came up the way it should before anyone
# initialises it.
#
# At this point "the way it should" means: 3 pods are Running but not Ready,
# because a fresh OpenBao is not initialised and is sealed. The script waits
# for that, prints the seal status and any error lines from each pod, and
# lists the tables OpenBao created in its PostgreSQL database. Those tables
# prove that OpenBao reached the database. It changes nothing in OpenBao.
#
# Run it: bash scripts/openbao/openbao-deploy-check.sh (after git push of the OpenBao layer, before init)
# Changes the cluster: no. It asks Flux to apply what is in Git now instead of
#   waiting for the interval; then it only reads. Prints no secrets.
#
# What it does:
#   1. Applies Git now: the HelmRepository, the database change, then OpenBao.
#        flux reconcile source git flux-system
#        flux reconcile kustomization infra-controllers / apps-database / apps-openbao
#   2. Shows the layers, the HelmRelease, the Certificate and the Ingress.
#        flux get kustomizations ; flux get helmreleases -n openbao
#   3. Waits up to 5 min until the 3 pods are Running (not Ready: sealed).
#        kubectl -n openbao wait pod -l app.kubernetes.io/name=openbao,component=server --for=jsonpath='{.status.phase}'=Running --timeout=300s
#   4. Shows the seal status and recent errors of each pod.
#        kubectl -n openbao exec <pod> -- bao status
#   5. Shows the tables OpenBao created in database openbao.
#        kubectl cnpg psql pg-openbao -n databases -- -d openbao -c '\dt'
#
# What you should see: 3 pods Running 0/1, "Initialized false" and "Sealed true"
#   before init, no error lines, and the tables openbao_kv_store and openbao_ha_locks.
# If it fails: pods not Running after 5 min: check
#   kubectl -n openbao describe pod <pod> and the PostgreSQL layer.
# Needs: flux, kubectl with the cnpg plugin.
set -euo pipefail

NS=openbao

echo "==> Flux: fetch Git, apply the new HelmRepository, the database change, then OpenBao"
flux reconcile source git flux-system
flux reconcile kustomization infra-controllers
flux reconcile kustomization apps-database
flux reconcile kustomization apps-openbao

echo
echo "==> Flux layers"
flux get kustomizations

echo
echo "==> HelmRelease, Certificate, Ingress"
flux get helmreleases -n "$NS"
kubectl -n "$NS" get certificate,ingress

echo
echo "==> Waiting for the 3 OpenBao pods to be Running (not Ready: sealed)"
kubectl -n "$NS" wait pod -l app.kubernetes.io/name=openbao,component=server \
  --for=jsonpath='{.status.phase}'=Running --timeout=300s
kubectl -n "$NS" get pods -o wide

echo
echo "==> Seal status per pod (exit code 2 = sealed, expected now)"
for pod in openbao-0 openbao-1 openbao-2; do
  echo "--- $pod"
  kubectl -n "$NS" exec "$pod" -- bao status 2>&1 | grep -E 'Initialized|Sealed|Storage Type|HA Enabled' || true
done

echo
echo "==> Errors in the OpenBao logs (empty is good)"
for pod in openbao-0 openbao-1 openbao-2; do
  kubectl -n "$NS" logs "$pod" --tail=200 | grep -iE '\[error\]|failed to' | tail -5 || true
done

echo
echo "==> PostgreSQL: tables created by OpenBao in database openbao"
kubectl cnpg psql pg-openbao -n databases -- -d openbao -c '\dt'
