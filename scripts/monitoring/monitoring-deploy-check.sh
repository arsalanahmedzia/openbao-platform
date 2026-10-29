#!/usr/bin/env bash
# Monitoring M1: after `git push`, lets Flux apply the new layer apps-monitoring
# and checks that the stack is running. Read-only apart from the Flux reconcile.
#
# What it does:
#   1. Fetches Git and reconciles the layers in order: infra-controllers (new
#      HelmRepository prometheus-community), then apps-monitoring.
#        flux reconcile source git flux-system
#        flux reconcile kustomization infra-controllers / apps-monitoring
#   2. Shows the HelmRelease, the pods, the Prometheus volume and the new CRDs.
#        kubectl -n monitoring get helmrelease,pods,pvc
#   3. Waits for the 4 pods to be Ready and prints PASS / FAIL.
#   4. Shows memory requests/limits per pod (actual use: docker stats, not here).
# Prints no secrets.
#   bash scripts/monitoring/monitoring-deploy-check.sh
set -uo pipefail

NS=monitoring
FAILS=0
ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

echo "==> 1. Flux"
flux reconcile source git flux-system
flux reconcile kustomization infra-controllers
flux reconcile kustomization apps-monitoring --timeout=15m || fail "apps-monitoring did not reconcile"
flux get helmreleases -n "$NS"

echo
echo "==> 2. Objects"
kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" get pvc
info "CRDs from the operator: $(kubectl get crd -o name | grep -c monitoring.coreos.com)"

echo
echo "==> 3. Ready checks"
check_ready() {  # check_ready <description> <label selector>
  if kubectl -n "$NS" wait pod -l "$2" --for=condition=Ready --timeout=300s >/dev/null 2>&1; then
    pass "$1 Ready"
  else
    fail "$1 not Ready"
  fi
}
check_ready "Prometheus"          app.kubernetes.io/name=prometheus
check_ready "Alertmanager"        app.kubernetes.io/name=alertmanager
check_ready "Prometheus Operator" app=kube-prometheus-stack-operator
check_ready "kube-state-metrics"  app.kubernetes.io/name=kube-state-metrics
[[ "$(kubectl -n "$NS" get pvc -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" == Bound ]] \
  && pass "Prometheus volume Bound" || fail "Prometheus volume not Bound"

echo
echo "==> 4. Memory requests / limits per container"
kubectl -n "$NS" get pods -o custom-columns='POD:.metadata.name,CONTAINER:.spec.containers[*].name,MEM_REQ:.spec.containers[*].resources.requests.memory,MEM_LIMIT:.spec.containers[*].resources.limits.memory'

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  M1 passed (now run bash scripts/test-gate.sh)" || { echo "$(ts) RESULT  M1: $FAILS check(s) failed"; exit 1; }
