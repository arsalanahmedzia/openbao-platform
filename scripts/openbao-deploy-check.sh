#!/usr/bin/env bash
# Step 2 of the OpenBao stage: after `git push`, makes Flux apply the new
# commits now (instead of waiting for the interval) and shows whether the
# OpenBao layer came up. Expected at this point: 3 pods Running but 0/1 Ready,
# because they are not initialised and sealed yet. Prints no secrets.
#   bash scripts/openbao-deploy-check.sh
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
