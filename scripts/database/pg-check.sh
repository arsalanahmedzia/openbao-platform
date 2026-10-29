#!/usr/bin/env bash
# pg-check.sh - checks that the PostgreSQL cluster pg-openbao is healthy and replicates.
# Run it: bash scripts/database/pg-check.sh (any time; after a failover or a restart)
# Changes the cluster: yes: creates one test table in database postgres (not
#   OpenBao's database openbao), writes one row and drops the table at the end.
#
# What it does:
#   1. Shows the CloudNativePG status: instances, primary, replication,
#      backups.
#        kubectl cnpg status pg-openbao -n databases
#   2. Checks 3 ready instances and one primary.
#        kubectl -n databases get cluster pg-openbao -o jsonpath='{.status.readyInstances}'
#   3. Checks every pod's role: the primary is not in recovery, each replica is.
#        kubectl -n databases exec <pod> -c postgres -- psql -d postgres -tA -c "SELECT pg_is_in_recovery();"
#   4. Checks that the primary streams to both replicas.
#        psql -c "SELECT application_name, state FROM pg_stat_replication;"   (on the primary)
#   5. Writes one row on the primary and waits up to 30 s until every replica
#      has it; a write on a replica must fail (replicas are read-only).
#        CREATE TABLE pg_check (...); INSERT ...   (primary)
#        SELECT note FROM pg_check;                (each replica)
#   6. Cleanup (trap, also on failure or Ctrl+C): drops the table on the primary.
#
# What you should see: PASS for 3 ready instances, the roles, 2 streaming
#   replicas, the row on each replica and the refused write. RESULT pg check passed.
# If it fails: "kubectl cnpg status did not answer within 30 s" usually means
#   the NetworkPolicy blocks the API server (docs/architecture.md, network
#   rules). A replica that never gets the row: see "Working WAL archiving" and
#   the replication section in the status output, and
#   docs/runbooks/postgres-backup-restore.md.
# Needs: kubectl with the cnpg plugin, access to the cluster.
set -uo pipefail

NS=databases
CLUSTER=pg-openbao
FAILS=0
ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

# sql <pod> <statement>: one psql call in database postgres, no headers
sql() { kubectl -n "$NS" exec "$1" -c postgres -- psql -d postgres -tA -c "$2"; }

PRIMARY=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
cleanup() { [[ -n $PRIMARY ]] && sql "$PRIMARY" "DROP TABLE IF EXISTS pg_check;" >/dev/null 2>&1; }
trap cleanup EXIT

echo "==> 1. CloudNativePG status"
timeout 30 kubectl cnpg status "$CLUSTER" -n "$NS" || fail "kubectl cnpg status did not answer within 30 s"

echo
echo "==> 2. Instances"
ready=$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.readyInstances}')
[[ $ready == 3 ]] && pass "3 instances ready" || fail "ready instances: ${ready:-none}"
[[ -n $PRIMARY ]] && pass "primary: $PRIMARY" || fail "no primary in the cluster status"
kubectl -n "$NS" get pods -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" -o wide -L cnpg.io/instanceRole

echo
echo "==> 3. Roles (pg_is_in_recovery: f = primary, t = replica)"
REPLICAS=()
for pod in $(kubectl -n "$NS" get pods -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" -o jsonpath='{.items[*].metadata.name}'); do
  rec=$(sql "$pod" "SELECT pg_is_in_recovery();" 2>/dev/null)
  if [[ $pod == "$PRIMARY" ]]; then
    [[ $rec == f ]] && pass "$pod is primary (not in recovery)" || fail "$pod should be primary, pg_is_in_recovery=$rec"
  else
    REPLICAS+=("$pod")
    [[ $rec == t ]] && pass "$pod is a replica (in recovery)" || fail "$pod should be a replica, pg_is_in_recovery=$rec"
  fi
done

echo
echo "==> 4. Streaming replication (on the primary)"
streams=$(sql "$PRIMARY" "SELECT application_name || ' ' || state FROM pg_stat_replication;" 2>/dev/null)
echo "$streams" | sed 's/^/        /'
[[ $(grep -c ' streaming$' <<<"$streams") -eq 2 ]] && pass "2 replicas streaming" || fail "not 2 streaming replicas"

echo
echo "==> 5. Write on the primary, read on every replica"
MARK="pg-check $(date -u +%FT%TZ)"
sql "$PRIMARY" "CREATE TABLE IF NOT EXISTS pg_check (id serial PRIMARY KEY, note text); INSERT INTO pg_check (note) VALUES ('$MARK');" >/dev/null \
  && info "row written on $PRIMARY: $MARK" || fail "write on the primary failed"
for pod in "${REPLICAS[@]}"; do
  seen=""
  for _ in $(seq 1 15); do
    seen=$(sql "$pod" "SELECT note FROM pg_check WHERE note = '$MARK';" 2>/dev/null)
    [[ $seen == "$MARK" ]] && break
    sleep 2
  done
  [[ $seen == "$MARK" ]] && pass "$pod has the row" || fail "$pod does not have the row after 30 s"
  if sql "$pod" "INSERT INTO pg_check (note) VALUES ('must fail');" >/dev/null 2>&1; then
    fail "$pod accepted a write (replicas must be read-only)"
  else
    pass "$pod refused the write (read-only)"
  fi
done

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  pg check passed" \
  || { echo "$(ts) RESULT  pg check: $FAILS check(s) failed"; exit 1; }
