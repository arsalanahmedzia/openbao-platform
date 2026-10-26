#!/usr/bin/env bash
# Test gate for the hardening stage: run after every change. Read-only: writes
# no files, uses no OpenBao token, prints no secrets (only the demo values).
# Checks Flux, OpenBao, PostgreSQL and External Secrets and ends with
# "GATE PASSED" or a list of failures.
#   bash scripts/test-gate.sh
set -uo pipefail

FAILS=()
check() {  # check <description> <command...>: PASS/FAIL line, collects failures
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; FAILS+=("$desc"); fi
}

echo "==> Flux"
flux reconcile source git flux-system >/dev/null 2>&1
check "all Flux layers Ready (waits up to 10 min)" \
  kubectl -n flux-system wait kustomization --all --for=condition=Ready --timeout=10m
flux get kustomizations

echo
echo "==> OpenBao"
kubectl -n openbao get pods -o wide -L openbao-active,openbao-sealed
check "3 OpenBao pods Ready (unsealed)" \
  kubectl -n openbao wait pod -l app.kubernetes.io/name=openbao,component=server --for=condition=Ready --timeout=30s
check "exactly one active OpenBao pod" \
  test "$(kubectl -n openbao get pods -l openbao-active=true -o name | wc -l)" -eq 1

echo
echo "==> PostgreSQL"
timeout 30 kubectl cnpg status pg-openbao -n databases 2>/dev/null |
  grep -E '^(Status|Instances|Ready instances|Working WAL archiving|Last Successful Backup):?' || true
check "kubectl cnpg status answers within 30 s (API server -> instance manager)" \
  timeout 30 kubectl cnpg status pg-openbao -n databases
check "PostgreSQL cluster healthy" \
  sh -c 'kubectl -n databases get cluster pg-openbao -o jsonpath="{.status.phase}" | grep -q "healthy"'
check "3 PostgreSQL instances ready" \
  test "$(kubectl -n databases get cluster pg-openbao -o jsonpath='{.status.readyInstances}')" = 3

echo
echo "==> External Secrets"
kubectl get clustersecretstore openbao
kubectl -n eso-demo get externalsecret,pushsecret
check "ClusterSecretStore openbao Ready" \
  kubectl wait clustersecretstore/openbao --for=condition=Ready --timeout=30s
check "ExternalSecret hello Ready" \
  kubectl -n eso-demo wait externalsecret/hello --for=condition=Ready --timeout=30s
check "pulled value is hello-from-openbao" \
  sh -c 'test "$(kubectl -n eso-demo get secret hello-from-openbao -o jsonpath="{.data.message}" | base64 -d)" = hello-from-openbao'
check "PushSecret push-demo Ready" \
  kubectl -n eso-demo wait pushsecret/push-demo --for=condition=Ready --timeout=30s

echo
if (( ${#FAILS[@]} == 0 )); then
  echo "GATE PASSED"
else
  echo "GATE FAILED: ${#FAILS[@]} check(s):"; printf '  - %s\n' "${FAILS[@]}"; exit 1
fi
