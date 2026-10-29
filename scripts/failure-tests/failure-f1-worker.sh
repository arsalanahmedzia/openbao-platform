#!/usr/bin/env bash
# failure-f1-worker.sh - failure test F1: stops a worker node and measures how the platform recovers.
#
# In plain words:
#   This test answers: what happens when a whole worker node dies? It picks
#   the worker that runs the active OpenBao pod (or the node you name) and
#   stops its Docker container, which is how a node failure looks in kind.
#   That node also runs the PostgreSQL primary, so both have to fail over.
#
#   While the node is gone, a background check calls OpenBao through Traefik
#   every 2 seconds, and the script notes the time of each event: the node
#   marked NotReady, a new PostgreSQL primary, OpenBao answering again. Then
#   it starts the node again, repairs the pod network if the node got a new
#   IP, and unseals the OpenBao pod that came back sealed. If you stop the
#   script early, it still starts the node again. The output also goes to
#   docs/evidence/07-f1-worker-script.txt.
#
# Run it: bash scripts/failure-tests/failure-f1-worker.sh [node-name] (default: the node with the active OpenBao pod; run test-gate.sh before and after)
# Changes the cluster: breaks something on purpose, asks first: stops a worker node container,
#   then starts it again and unseals OpenBao.
#
# What it does:
#   1. Picks the worker: the one given as argument, or by default the one
#      running the ACTIVE OpenBao pod. Shows every pod on it, the PostgreSQL
#      primary and the active OpenBao pod.
#        kubectl get pods -A --field-selector spec.nodeName=<node>
#   2. Asks y/N.
#   3. Starts a background probe: OpenBao health through Traefik every 2 s
#      (HTTP code: 200 active, 503 no active pod / sealed, 502/504 or 000 no
#      answer). Uses only the public demo CA certificate.
#        curl --resolve openbao.demo.local:443:127.0.0.1 --cacert <ca> https://openbao.demo.local/v1/sys/health
#   4. Breaks: stops the node container (docker stop gives the processes 10 s
#      to shut down cleanly; it is not a power cut).
#        docker stop <node>
#   5. Watches (up to 10 min) and notes the time of: node NotReady, new
#      PostgreSQL primary (if the primary was on the node), OpenBao answering
#      200 again, ESO controller replaced on another node (if it was on it).
#   6. Recovers: starts the node, waits for Ready, shows the OpenBao pod on it
#      came back SEALED, runs the pod-network check (the node may get another
#      IP), then the unseal script.
#        docker start <node>
#        bash scripts/after-restart/kind-fix-pod-network.sh ; bash scripts/after-restart/openbao-unseal.sh
#   7. Cleanup (trap, also on failure or Ctrl+C): starts the node if it is
#      still stopped, stops the probe.
#
# Output: PASS / FAIL / INFO lines with UTC times and a timeline, also written
# to docs/evidence/07-f1-worker-script.txt (the manual run's evidence file is
# not touched). No secrets are printed; unseal keys go via stdin in the
# unseal script.
#
# What you should see: PASS / INFO lines with a timeline (node NotReady, new primary, OpenBao
#   answering 200 again), then "RESULT F1 passed (run scripts/checks/test-gate.sh next)".
# If it fails: if the script stops early, its trap starts the node again; then run
#   scripts/after-restart/kind-fix-pod-network.sh and scripts/after-restart/openbao-unseal.sh.
# Needs: docker, kubectl, curl, jq, the unseal keys.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=docs/evidence/07-f1-worker-script.txt
CLUSTER=openbao-platform
TMP=$(mktemp -d)
PROBE_LOG="$TMP/probe.log"
FAILS=0

ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }
node_ready() { kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; }
primary()    { kubectl -n databases get cluster pg-openbao -o jsonpath='{.status.currentPrimary}'; }

echo "==> 1. Choose the worker"
NODE=${1:-$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].spec.nodeName}')}
[[ "$NODE" == "$CLUSTER"-worker* ]] || { echo "not a worker of $CLUSTER: '$NODE'"; exit 1; }
[[ "$(node_ready)" == True ]] || { echo "$NODE is not Ready: run scripts/checks/test-gate.sh first"; exit 1; }
PRIMARY=$(primary); PRIMARY_NODE=$(kubectl -n databases get pod "$PRIMARY" -o jsonpath='{.spec.nodeName}')
ACTIVE=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')
BAO_ON_NODE=$(kubectl -n openbao get pods -l app.kubernetes.io/name=openbao,component=server \
  --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')
ESO_NODE=$(kubectl -n external-secrets get pods -l app.kubernetes.io/name=external-secrets -o jsonpath='{.items[0].spec.nodeName}')
kubectl get pods -A -o wide --field-selector spec.nodeName="$NODE"
echo "node: $NODE | OpenBao active: $ACTIVE, on this node: ${BAO_ON_NODE:-none} | PostgreSQL primary: $PRIMARY on $PRIMARY_NODE | ESO controller on $ESO_NODE"

read -r -p "This stops the node container $NODE. Continue? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { rm -rf "$TMP"; echo "aborted, nothing changed"; exit 1; }

PROBE_PID=""
cleanup() {
  [[ -n "$PROBE_PID" ]] && kill "$PROBE_PID" 2>/dev/null || true
  if [[ "$(docker inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null)" != true ]]; then
    info "cleanup: starting $NODE again"; docker start "$NODE" >/dev/null || true
    info "cleanup: then run scripts/after-restart/kind-fix-pod-network.sh and scripts/after-restart/openbao-unseal.sh"
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

exec > >(tee "$OUT") 2>&1
echo "# F1: a worker node dies (script)   $(date -u +%Y-%m-%d)"
echo "# Command: bash scripts/failure-tests/failure-f1-worker.sh $NODE"
echo
info "start: node $NODE; OpenBao active $ACTIVE (on this node: ${BAO_ON_NODE:-none}); PostgreSQL primary $PRIMARY on $PRIMARY_NODE; ESO controller on $ESO_NODE"

kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"
(
  while true; do
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' --resolve openbao.demo.local:443:127.0.0.1 \
           --cacert "$TMP/ca.crt" https://openbao.demo.local/v1/sys/health || true)
    echo "$(date -u +%T) $(date +%s) ${code:-000}" >> "$PROBE_LOG"
    sleep 2
  done
) &
PROBE_PID=$!
sleep 6
grep -q ' 200$' "$PROBE_LOG" && pass "OpenBao answers 200 before the break" || fail "OpenBao not answering 200 before the break"

echo
echo "==> 4. Break: docker stop $NODE"
T0=$(date +%s); info "stopping $NODE"
docker stop "$NODE" >/dev/null
info "stopped after $(( $(date +%s) - T0 )) s"

echo
echo "==> 5. Watch (up to 10 min)"
T_NOTREADY=""; T_PRIMARY=""; T_BAO=""; T_ESO=""
NEED_PRIMARY=no; [[ "$PRIMARY_NODE" == "$NODE" ]] && NEED_PRIMARY=yes
NEED_ESO=no;     [[ "$ESO_NODE" == "$NODE" ]] && NEED_ESO=yes
while (( $(date +%s) - T0 < 600 )); do
  now=$(( $(date +%s) - T0 ))
  [[ -z "$T_NOTREADY" && "$(node_ready)" != True ]] && { T_NOTREADY=$now; info "node NotReady after $now s"; }
  if [[ "$NEED_PRIMARY" == yes && -z "$T_PRIMARY" ]]; then
    p=$(primary); [[ -n "$p" && "$p" != "$PRIMARY" ]] && { T_PRIMARY=$now; info "new PostgreSQL primary $p after $now s"; }
  fi
  if [[ -z "$T_BAO" ]] && awk -v t="$T0" '$2>t && $3!="200"{bad=1} $2>t && $3=="200" && bad{ok=1} END{exit !ok}' "$PROBE_LOG"; then
    T_BAO=$(awk -v t="$T0" '$2>t && $3!="200"{bad=1} $2>t && $3=="200" && bad{print $2-t; exit}' "$PROBE_LOG")
    info "OpenBao answers 200 again after $T_BAO s ($(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}') active)"
  fi
  if [[ "$NEED_ESO" == yes && -z "$T_ESO" ]]; then
    n=$(kubectl -n external-secrets get pods -l app.kubernetes.io/name=external-secrets --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | grep -vc "^$NODE$" || true)
    (( n > 0 )) && { T_ESO=$now; info "ESO controller running on another node after $now s"; }
  fi
  [[ -n "$T_NOTREADY" && -n "$T_BAO" && ( "$NEED_PRIMARY" == no || -n "$T_PRIMARY" ) && ( "$NEED_ESO" == no || -n "$T_ESO" ) ]] && break
  sleep 3
done
OUTAGE=$(awk -v t="$T0" '$2>t && $3!="200"' "$PROBE_LOG" | wc -l)
info "OpenBao health probes without 200 after the stop: $OUTAGE (codes: $(awk -v t="$T0" '$2>t && $3!="200"{print $3}' "$PROBE_LOG" | sort | uniq -c | tr -s ' ' | tr '\n' ' '))"
[[ -n "$T_BAO" ]] && pass "OpenBao answered again through a standby after $T_BAO s" || fail "OpenBao did not answer 200 again within 10 min"
[[ "$NEED_PRIMARY" == no || -n "$T_PRIMARY" ]] && pass "PostgreSQL primary available (${T_PRIMARY:-no failover needed})" || fail "no new PostgreSQL primary within 10 min"
if [[ "$NEED_ESO" == no ]]; then pass "ESO controller running (was not on this node)"
elif [[ -n "$T_ESO" ]]; then pass "ESO controller replaced on another node after $T_ESO s"
else fail "ESO controller not replaced within 10 min"; fi
kubectl -n eso-demo get secret hello-from-openbao -o jsonpath='{.data.message}' | base64 -d | grep -qx hello-from-openbao \
  && pass "Secret hello-from-openbao kept its value" || fail "Secret hello-from-openbao changed"

echo
echo "==> 6. Recover: docker start $NODE"
T2=$(date +%s); docker start "$NODE" >/dev/null
kubectl wait --for=condition=Ready node/"$NODE" --timeout=300s
pass "$NODE Ready again after $(( $(date +%s) - T2 )) s"
if [[ -n "$BAO_ON_NODE" ]]; then
  sleep 20
  SEALED=$(kubectl -n openbao exec "$BAO_ON_NODE" -- bao status -format=json 2>/dev/null | jq -r .sealed || true)
  [[ "$SEALED" == true ]] && pass "$BAO_ON_NODE came back SEALED (as expected)" || info "$BAO_ON_NODE sealed=${SEALED:-no answer yet}"
fi
echo "--- pod network check (the node may have another IP now)"
bash scripts/after-restart/kind-fix-pod-network.sh
echo "--- unseal"
bash scripts/after-restart/openbao-unseal.sh | grep -E 'unsealed|HA Mode|no answer'
kubectl -n databases get pods -o wide -L cnpg.io/instanceRole

echo
echo "==> Timeline (seconds after docker stop)"
echo "  node NotReady:           ${T_NOTREADY:-?}"
echo "  new PostgreSQL primary:  ${T_PRIMARY:-not needed}"
echo "  OpenBao 200 again:       ${T_BAO:-?}"
echo "  ESO controller replaced: ${T_ESO:-not needed}"
echo
(( FAILS == 0 )) && echo "$(ts) RESULT  F1 passed (run scripts/checks/test-gate.sh next)" || { echo "$(ts) RESULT  F1: $FAILS check(s) failed"; exit 1; }
