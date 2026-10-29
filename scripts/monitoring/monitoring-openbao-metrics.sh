#!/usr/bin/env bash
# Monitoring M2, OpenBao: after `git push`, rolls out the new OpenBao config
# (metrics listener on port 9101, HTTPS with the demo CA) and checks the
# metrics. Prints no keys or tokens; the metrics need no token. The CA
# certificate is public and only written to a temporary file.
#
# What it does:
#   1. Rolls out the config change: Flux reconcile, restart the outdated pods
#      one at a time (standbys first), unseal each new pod.
#        bash scripts/openbao-tls-rollout.sh
#   2. Lets Flux apply the Certificate prometheus-client (its Secret holds the
#      demo CA for Prometheus) and the PodMonitor; checks it is the same CA
#      that signed the OpenBao certificate.
#        flux reconcile kustomization apps-monitoring
#   3. Reads the metrics of one pod through a port-forward over HTTPS, verified
#      like Prometheus does it: demo CA + name openbao.openbao.svc.
#        kubectl -n openbao port-forward pod/openbao-0 19101:9101
#        curl --cacert ca.crt --resolve openbao.openbao.svc:19101:127.0.0.1 \
#          https://openbao.openbao.svc:19101/v1/sys/metrics?format=prometheus
#   4. Checks: plain HTTP on 9101 fails, the listener serves nothing but
#      metrics, no metrics through Traefik.
#   5. Shows the scrape config Prometheus generated (CA, server name, no
#      insecure_skip_verify) and the target state (down until M3 adds the
#      NetworkPolicy that lets Prometheus reach port 9101).
#   bash scripts/monitoring/monitoring-openbao-metrics.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
NAME=openbao.openbao.svc
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

echo "==> 1. Rollout (pods restart sealed and are unsealed one by one)"
bash scripts/openbao-tls-rollout.sh || fail "rollout script failed"
kubectl -n "$NS" wait pod -l "$SELECTOR" --for=condition=Ready --timeout=120s >/dev/null 2>&1 \
  && pass "3 OpenBao pods Ready (unsealed)" || fail "not all OpenBao pods Ready"
ports=$(kubectl -n "$NS" get pods -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.containers[0].ports[?(@.name=="metrics")].containerPort}{" "}{end}')
info "metrics container port per pod: $ports"
[[ $(grep -o '=9101' <<<"$ports" | wc -l) -eq 3 ]] && pass "all 3 pods declare port 9101 (metrics)" \
  || fail "not all pods declare port 9101"

echo
echo "==> 2. Certificate (demo CA for Prometheus) and PodMonitor"
flux reconcile source git flux-system
flux reconcile kustomization infra-configs
flux reconcile kustomization apps-monitoring
kubectl -n monitoring wait certificate/prometheus-client --for=condition=Ready --timeout=120s >/dev/null 2>&1 \
  && pass "Certificate monitoring/prometheus-client Ready" || fail "Certificate monitoring/prometheus-client not Ready"
kubectl -n monitoring get podmonitor openbao >/dev/null 2>&1 && pass "PodMonitor monitoring/openbao exists" \
  || fail "PodMonitor monitoring/openbao missing"
kubectl -n monitoring get secret prometheus-client-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca-monitoring.crt"
kubectl -n "$NS" get secret openbao-server-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"
kubectl -n "$NS" get secret openbao-server-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TMP/server.crt"
info "CA in monitoring: $(openssl x509 -in "$TMP/ca-monitoring.crt" -noout -subject -fingerprint -sha256 2>/dev/null | tr '\n' ' ')"
if openssl verify -CAfile "$TMP/ca-monitoring.crt" "$TMP/server.crt" >/dev/null 2>&1; then
  pass "CA in monitoring/prometheus-client-tls verifies the OpenBao certificate"
else
  fail "CA in monitoring/prometheus-client-tls does not verify the OpenBao certificate"
fi
openssl x509 -in "$TMP/server.crt" -noout -checkhost "$NAME" 2>/dev/null | grep -q 'does match' \
  && pass "OpenBao certificate covers the name $NAME" || fail "OpenBao certificate does not cover $NAME"

echo
echo "==> 3. Metrics from openbao-0 over verified HTTPS (port-forward 19101 -> 9101)"
if forward "$NS" pod/openbao-0 19101:9101; then
  code=$(curl -s -o "$TMP/metrics" -w '%{http_code}' --cacert "$TMP/ca-monitoring.crt" \
         --resolve "$NAME:19101:127.0.0.1" "https://$NAME:19101/v1/sys/metrics?format=prometheus")
  info "GET https://$NAME:9101/v1/sys/metrics?format=prometheus -> HTTP $code, $(grep -vc '^#' "$TMP/metrics") sample lines"
  [[ $code == 200 ]] && pass "metrics over HTTPS, certificate verified, no token" \
    || fail "metrics over verified HTTPS failed (HTTP $code; 000 = TLS or connection error)"
  if grep -q '^vault_core_unsealed' "$TMP/metrics"; then
    pass "vault_core_unsealed present: $(grep '^vault_core_unsealed' "$TMP/metrics")"
  else
    info "vault_core_unsealed not in the output (OpenBaoSealed alert will use pod readiness)"
  fi
  info "distinct metric names: $(grep -v '^#' "$TMP/metrics" | sed 's/[{ ].*//' | sort -u | wc -l)"

  echo
  echo "==> 4. Negative checks"
  code=$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:19101/v1/sys/metrics?format=prometheus')
  [[ $code != 200 ]] && pass "plain HTTP on 9101 -> HTTP $code (no metrics without TLS)" \
    || fail "plain HTTP on 9101 still serves metrics"
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$TMP/ca-monitoring.crt" \
         --resolve "$NAME:19101:127.0.0.1" "https://$NAME:19101/v1/sys/health")
  [[ $code != 200 ]] && pass "GET :9101/v1/sys/health -> HTTP $code (not served)" \
    || fail "GET :9101/v1/sys/health -> HTTP 200 (metrics_only not active)"
else
  fail "port-forward to openbao-0:9101 did not start"
fi
code=$(curl -s -o "$TMP/traefik" -w '%{http_code}' --resolve openbao.demo.local:443:127.0.0.1 \
       --cacert "$TMP/ca.crt" 'https://openbao.demo.local/v1/sys/metrics?format=prometheus')
if [[ $code != 200 ]] && ! grep -q '^vault_' "$TMP/traefik"; then
  pass "GET https://openbao.demo.local/v1/sys/metrics -> HTTP $code, no metrics through Traefik"
else
  fail "metrics reachable through Traefik (HTTP $code)"
fi

echo
echo "==> 5. Prometheus: generated scrape config and targets (targets down until M3)"
if forward monitoring svc/kube-prometheus-stack-prometheus 19090:9090; then
  # The operator needs a moment to write the new config and the reloader to load it.
  for _ in $(seq 1 12); do
    curl -s http://127.0.0.1:19090/api/v1/status/config | jq -r .data.yaml > "$TMP/prom.yaml"
    grep -q 'job_name: podMonitor/monitoring/openbao/' "$TMP/prom.yaml" && grep -A40 'job_name: podMonitor/monitoring/openbao/' "$TMP/prom.yaml" | grep -q 'server_name' && break
    sleep 10
  done
  awk '/job_name: podMonitor\/monitoring\/openbao\//{p=1} /^ *- job_name:/&&!/podMonitor\/monitoring\/openbao\//{p=0} p' "$TMP/prom.yaml" > "$TMP/job.yaml"
  grep -E '^\s*(scheme|tls_config|ca_file|ca|server_name|insecure_skip_verify):' "$TMP/job.yaml" | sed 's/^/        /'
  grep -q 'scheme: https' "$TMP/job.yaml" && grep -q "server_name: $NAME" "$TMP/job.yaml" \
    && grep -qE '^\s*ca(_file)?:' "$TMP/job.yaml" && pass "scrape config: https, CA file, server_name $NAME" \
    || fail "scrape config for openbao is missing https / CA / server_name"
  grep -q 'insecure_skip_verify: true' "$TMP/job.yaml" && fail "scrape config skips certificate verification" \
    || pass "scrape config verifies certificates (no insecure_skip_verify: true)"
  curl -s 'http://127.0.0.1:19090/api/v1/targets?state=active' |
    jq -r '.data.activeTargets[] | select(.labels.namespace=="openbao")
           | "        \(.scrapeUrl)  health=\(.health)  \(.lastError)"'
else
  fail "port-forward to Prometheus did not start"
fi

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  M2 OpenBao passed (now run bash scripts/test-gate.sh)" \
  || { echo "$(ts) RESULT  M2 OpenBao: $FAILS check(s) failed"; exit 1; }
