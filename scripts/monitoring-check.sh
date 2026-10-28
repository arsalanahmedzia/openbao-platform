#!/usr/bin/env bash
# Monitoring M5: read-only health check of the monitoring stack. Opens
# port-forwards to Prometheus and Alertmanager, lists every scrape target
# (up/down), checks that the 8 platform alert rules are loaded and healthy,
# and lists pending/firing alerts. Changes nothing; prints no secrets.
#
# What it does:
#   1. kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090
#      kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 19093:9093
#   2. Targets:  curl http://127.0.0.1:19090/api/v1/targets
#   3. Rules:    curl http://127.0.0.1:19090/api/v1/rules  (group "platform")
#   4. Alerts:   curl http://127.0.0.1:19090/api/v1/alerts
#                curl http://127.0.0.1:19093/api/v2/alerts (what Alertmanager received)
# A firing alert is a FAIL (something in the platform is broken).
#
#   bash scripts/monitoring-check.sh
#   bash scripts/monitoring-check.sh --wait-firing OpenBaoSealed [minutes]
#     waits until that alert fires (default up to 10 min), for failure tests:
#     then a firing alert of that name is a PASS.
set -uo pipefail

WAIT_ALERT=""
WAIT_MIN=10
if [[ ${1:-} == --wait-firing ]]; then WAIT_ALERT=${2:?alert name}; WAIT_MIN=${3:-10}; fi

RULES=(OpenBaoSealed ExternalSecretNotReady PushSecretNotReady ClusterSecretStoreNotReady
       ExternalSecretsControllerDown PostgresNotHealthy BackupFailedOrTooOld NodeNotReady)
FAILS=0
ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

TMP=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

# forward <service> <local:remote> <ready path>: background port-forward, waits until it answers
forward() {
  kubectl -n monitoring port-forward "svc/$1" "$2" >/dev/null 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 20); do curl -sf -o /dev/null "http://127.0.0.1:${2%%:*}$3" && return 0; sleep 1; done
  return 1
}
P=http://127.0.0.1:19090
A=http://127.0.0.1:19093

echo "==> 1. Port-forwards"
forward kube-prometheus-stack-prometheus 19090:9090 /-/ready && pass "Prometheus ready" \
  || { fail "Prometheus not reachable"; exit 1; }
forward kube-prometheus-stack-alertmanager 19093:9093 /-/ready && pass "Alertmanager ready" \
  || fail "Alertmanager not reachable"

if [[ -n $WAIT_ALERT ]]; then
  echo
  echo "==> Waiting up to $WAIT_MIN min for $WAIT_ALERT to fire"
  for _ in $(seq 1 $((WAIT_MIN * 6))); do
    state=$(curl -s "$P/api/v1/alerts" | jq -r --arg a "$WAIT_ALERT" \
      '[.data.alerts[] | select(.labels.alertname==$a) | .state] | if index("firing") then "firing" elif length>0 then .[0] else "inactive" end')
    echo "$(ts) $WAIT_ALERT: $state"
    [[ $state == firing ]] && break
    sleep 10
  done
fi

echo
echo "==> 2. Scrape targets"
curl -s "$P/api/v1/targets?state=active" > "$TMP/targets.json"
jq -r '.data.activeTargets[] | "        \(.health)  \(.labels.job)  \(.labels.pod // .labels.instance)  \(.scrapeUrl)  \(.lastError)"' \
  "$TMP/targets.json" | sort -k2
total=$(jq '.data.activeTargets | length' "$TMP/targets.json")
down=$(jq '[.data.activeTargets[] | select(.health!="up")] | length' "$TMP/targets.json")
(( total > 0 && down == 0 )) && pass "all $total targets up" || fail "$down of $total targets not up"

echo
echo "==> 3. Alert rules (group platform)"
curl -s "$P/api/v1/rules?type=alert" > "$TMP/rules.json"
for r in "${RULES[@]}"; do
  h=$(jq -r --arg r "$r" '[.data.groups[] | select(.name=="platform") | .rules[] | select(.name==$r)][0] | "\(.health) \(.lastError // "")"' "$TMP/rules.json")
  [[ $h == "ok "* ]] && pass "rule $r loaded, health ok" || fail "rule $r: ${h:-not loaded}"
done

echo
echo "==> 4. Alerts (Prometheus: pending/firing; Alertmanager: received)"
curl -s "$P/api/v1/alerts" > "$TMP/alerts.json"
jq -r '.data.alerts[] | "        \(.state)  \(.labels.alertname)  \(.labels.severity)  since \(.activeAt)  \(.annotations.summary)"' "$TMP/alerts.json"
[[ $(jq '.data.alerts | length' "$TMP/alerts.json") -eq 0 ]] && info "no pending or firing alerts"
curl -s "$A/api/v2/alerts" | jq -r '.[] | "        alertmanager: \(.status.state)  \(.labels.alertname)  \(.labels.pod // .labels.name // .labels.node // "")  since \(.startsAt)"'
firing=$(jq -r '.data.alerts[] | select(.state=="firing") | .labels.alertname' "$TMP/alerts.json" | sort -u)
for a in $firing; do
  if [[ $a == "$WAIT_ALERT" ]]; then pass "$a is firing (expected)"
  elif [[ -n $WAIT_ALERT ]]; then info "$a is firing too (side effect of the failure test)"
  else fail "$a is firing"; fi
done
[[ -n $WAIT_ALERT ]] && ! grep -qx "$WAIT_ALERT" <<<"$firing" && fail "$WAIT_ALERT did not fire within $WAIT_MIN min"
[[ -z $firing ]] && pass "no firing alerts"

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  monitoring check passed" \
  || { echo "$(ts) RESULT  monitoring check: $FAILS check(s) failed"; exit 1; }
