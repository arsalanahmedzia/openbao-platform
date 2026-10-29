#!/usr/bin/env bash
# test-gate.sh - read-only check of the whole platform; ends with GATE PASSED or a list of failures.
# Run it: bash scripts/checks/test-gate.sh (after every change and before and after every failure test)
# Changes the cluster: no. It asks Flux to fetch Git once; writes no files, uses
#   no OpenBao token, prints no secrets (only the demo values).
#
# What it does:
#   1. Flux: fetches Git and waits up to 10 min until every layer is Ready.
#        flux reconcile source git flux-system
#        kubectl -n flux-system wait kustomization --all --for=condition=Ready --timeout=10m
#   2. OpenBao: 3 pods Ready (Ready means unsealed) and exactly one active.
#        kubectl -n openbao wait pod -l app.kubernetes.io/name=openbao,component=server --for=condition=Ready --timeout=30s
#   3. PostgreSQL: kubectl cnpg status answers within 30 s (the API server
#      reaches the instance manager), the cluster is healthy, 3 instances ready.
#        timeout 30 kubectl cnpg status pg-openbao -n databases
#   4. External Secrets: store, ExternalSecret and PushSecret Ready, and the
#      pulled value is hello-from-openbao.
#        kubectl wait clustersecretstore/openbao --for=condition=Ready --timeout=30s
#   5. Monitoring: all targets up, 8 alert rules ok, no alert firing. On a
#      FAIL it prints the check's FAIL lines, firing alerts and down targets.
#        bash "$(dirname "$0")/../monitoring/monitoring-check.sh"
#
# What you should see: one PASS line per check and GATE PASSED at the end.
# If it fails: GATE FAILED lists the failed checks. Sealed pods: run
#   scripts/after-restart/openbao-unseal.sh. Right after an unseal, alerts from
#   the sealed time can still be firing for about a minute; run the gate again.
#   Monitoring details: scripts/monitoring/monitoring-check.sh.
# Needs: kubectl with the cnpg plugin, flux, jq, curl.
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
echo "==> Monitoring"
MON=$(bash "$(dirname "$0")/../monitoring/monitoring-check.sh" 2>&1)
MON_RC=$?
check "monitoring: all targets up, 8 alert rules ok, no alert firing" test "$MON_RC" -eq 0
# On a FAIL, show why: the check's FAIL lines, firing alerts, targets not up
(( MON_RC == 0 )) || grep -E 'FAIL |^ +(firing|down) ' <<<"$MON" | sed 's/^ */        /'

echo
if (( ${#FAILS[@]} == 0 )); then
  echo "GATE PASSED"
else
  echo "GATE FAILED: ${#FAILS[@]} check(s):"; printf '  - %s\n' "${FAILS[@]}"; exit 1
fi
