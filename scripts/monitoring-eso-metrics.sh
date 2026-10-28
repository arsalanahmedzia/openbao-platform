#!/usr/bin/env bash
# Monitoring M2, External Secrets: after `git push`, lets Flux apply the HTTPS
# metrics change of the ESO controller (certificate from the demo CA) and the
# PodMonitor, and checks it the way Prometheus does. Prints no secrets (the
# metrics only carry object names and conditions; the CA certificate is public
# and only written to a temporary file).
#
# What it does:
#   1. Flux: infra-configs must already have created the certificate Secret
#      (first push), then infra-controllers rolls the controller (second push),
#      then apps-monitoring applies the PodMonitor.
#        flux reconcile kustomization infra-configs / infra-controllers / apps-monitoring
#   2. Reads the metrics through a port-forward over HTTPS, verified with the
#      demo CA and the certificate's name (a self-signed fallback would fail):
#        kubectl -n external-secrets port-forward deploy/external-secrets 18080:8080
#        curl --cacert ca.crt --resolve external-secrets-metrics.external-secrets.svc:18080:127.0.0.1 \
#          https://external-secrets-metrics.external-secrets.svc:18080/metrics
#   3. Negative check: plain HTTP on 8080 gives no metrics.
#   4. Shows the status metrics needed for the alerts in M4.
#   5. Prometheus: generated scrape config (https, CA, server_name, no
#      insecure_skip_verify) and the target, which must be up (M3 is in place).
#   bash scripts/monitoring-eso-metrics.sh
set -uo pipefail

NS=external-secrets
NAME=external-secrets-metrics.external-secrets.svc
FAILS=0
ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

TMP=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

# forward <namespace> <target> <local:remote>: background port-forward, waits
# until the local port accepts connections (any answer, also a TLS error)
forward() {
  kubectl -n "$1" port-forward "$2" "$3" >/dev/null 2>&1 &
  PIDS+=($!)
  local port=${3%%:*}
  for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:$port/"; [[ $? -ne 7 ]] && return 0   # 7 = could not connect
    sleep 1
  done
  return 1
}

echo "==> 1. Flux"
flux reconcile source git flux-system
flux reconcile kustomization infra-configs
kubectl -n "$NS" wait certificate/external-secrets-metrics --for=condition=Ready --timeout=120s >/dev/null 2>&1 \
  && pass "Certificate $NS/external-secrets-metrics Ready" \
  || { fail "Certificate $NS/external-secrets-metrics not Ready: push the certificate commit first"; exit 1; }
flux reconcile kustomization infra-controllers || fail "infra-controllers did not reconcile"
kubectl -n "$NS" rollout status deploy/external-secrets --timeout=180s || fail "ESO controller rollout not finished"
args=$(kubectl -n "$NS" get deploy external-secrets -o jsonpath='{.spec.template.spec.containers[0].args}')
grep -q -- '--metrics-secure=true' <<<"$args" && grep -q -- '--metrics-cert-name=tls.crt' <<<"$args" \
  && pass "controller runs with --metrics-secure=true --metrics-cert-name=tls.crt" \
  || fail "controller args missing --metrics-secure / --metrics-cert-name=tls.crt"
flux reconcile kustomization apps-monitoring
kubectl -n monitoring get secret prometheus-client-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"

echo
echo "==> 2. Metrics over verified HTTPS (port-forward 18080 -> 8080)"
if forward "$NS" deploy/external-secrets 18080:8080; then
  code=$(curl -s -o "$TMP/metrics" -w '%{http_code}' --cacert "$TMP/ca.crt" \
         --resolve "$NAME:18080:127.0.0.1" "https://$NAME:18080/metrics")
  info "GET https://$NAME:8080/metrics -> HTTP $code, $(grep -vc '^#' "$TMP/metrics") sample lines"
  [[ $code == 200 ]] && pass "metrics over HTTPS, certificate verified (demo CA, $NAME)" \
    || fail "metrics over verified HTTPS failed (HTTP $code; 000 = TLS error, e.g. self-signed fallback)"
  grep -v '^#' "$TMP/metrics" | sed 's/[{ ].*//' | sort -u > "$TMP/names"

  echo
  echo "==> 3. Negative check"
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/metrics)
  [[ $code != 200 ]] && pass "plain HTTP on 8080 -> HTTP $code (no metrics without TLS)" \
    || fail "plain HTTP on 8080 still serves metrics"

  echo
  echo "==> 4. Status metrics for the alerts (M4)"
  for m in externalsecret_status_condition clustersecretstore_status_condition pushsecret_status_condition; do
    if grep -qx "$m" "$TMP/names"; then
      pass "$m present:"
      grep "^$m{" "$TMP/metrics" | sed 's/^/        /'
    else
      fail "$m missing"
    fi
  done
else
  fail "port-forward to deploy/external-secrets:8080 did not start"
fi

echo
echo "==> 5. Prometheus: scrape config and target (waits up to 2 min for up)"
if forward monitoring svc/kube-prometheus-stack-prometheus 19090:9090; then
  for _ in $(seq 1 12); do
    curl -s http://127.0.0.1:19090/api/v1/status/config | jq -r .data.yaml > "$TMP/prom.yaml"
    awk '/job_name: podMonitor\/monitoring\/external-secrets\//{p=1} /^ *- job_name:/&&!/podMonitor\/monitoring\/external-secrets\//{p=0} p' \
      "$TMP/prom.yaml" > "$TMP/job.yaml"
    curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' |
      jq -r '.data.activeTargets[] | select(.labels.namespace=="external-secrets")
             | "        \(.scrapeUrl)  health=\(.health)  \(.lastError)"' > "$TMP/targets"
    grep -q 'scheme: https' "$TMP/job.yaml" && grep -q 'health=up' "$TMP/targets" && break
    sleep 10
  done
  grep -E '^\s*(scheme|tls_config|ca_file|ca|server_name|insecure_skip_verify):' "$TMP/job.yaml" | sed 's/^/        /'
  grep -q 'scheme: https' "$TMP/job.yaml" && grep -q "server_name: $NAME" "$TMP/job.yaml" \
    && grep -qE '^\s*ca(_file)?:' "$TMP/job.yaml" && pass "scrape config: https, CA file, server_name $NAME" \
    || fail "scrape config for external-secrets is missing https / CA / server_name"
  grep -q 'insecure_skip_verify: true' "$TMP/job.yaml" && fail "scrape config skips certificate verification" \
    || pass "scrape config verifies certificates (no insecure_skip_verify: true)"
  cat "$TMP/targets"
  grep -q '^ *https://.*health=up' "$TMP/targets" && pass "Prometheus scrapes the ESO controller over verified HTTPS (up)" \
    || fail "ESO target not up over https"
else
  fail "port-forward to Prometheus did not start"
fi

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  ESO metrics TLS passed (now run bash scripts/test-gate.sh)" \
  || { echo "$(ts) RESULT  ESO metrics TLS: $FAILS check(s) failed"; exit 1; }
