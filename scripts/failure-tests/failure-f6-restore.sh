#!/usr/bin/env bash
# failure-f6-restore.sh - failure test F6: point-in-time restore into a new temporary cluster, checked with two marker rows.
#
# In plain words:
#   This test answers: can a backup really bring the data back to an exact
#   moment in the past (point-in-time recovery)? It writes a marker row A into
#   the live cluster, notes the time, then writes a row B. It makes sure the
#   change log (WAL) up to that time is stored in S3.
#
#   Then it creates a new, temporary PostgreSQL cluster from the backup, told
#   to stop at the noted time. The live cluster is never overwritten; the
#   temporary one does not archive its own changes, so it cannot touch the
#   backups. If the restore is right, row A exists and row B does not. At the
#   end the temporary cluster and the marker table are deleted, also if the
#   script fails. The output also goes to docs/evidence/07-f6-restore.txt.
#
# Run it: bash scripts/failure-tests/failure-f6-restore.sh (run test-gate.sh before and after)
# Changes the cluster: yes, asks first: writes 2 test rows into pg-openbao (database postgres)
#   and creates the temporary cluster pg-restore-test; the trap deletes both.
#
# What it does:
#   1. Checks the start state: pg-openbao healthy, WAL archiving OK, a
#      completed base backup exists; lists the backups (does one come from
#      the daily schedule at 12:00 UTC?).
#        kubectl -n databases get backup
#   2. Asks y/N.
#   3. Writes marker rows into the live cluster, database "postgres" (not
#      OpenBao's database "openbao"): row A, then notes the target time, then
#      row B. Forces a WAL switch and waits until that WAL file is archived in
#      S3, so the restore can replay past the target time.
#        kubectl cnpg psql pg-openbao -n databases -- -d postgres -c "INSERT ..."
#        SELECT pg_walfile_name(pg_switch_wal());   SELECT ... FROM pg_stat_archiver;
#   4. Creates the restore cluster pg-restore-test (1 instance) from the S3
#      backup with recoveryTarget.targetTime = the noted time; same spec as
#      docs/runbooks/restore-example.yaml. A TEMPORARY manual object, not in
#      Git; it does not archive WAL itself, so it never writes to the backups.
#        kubectl apply -f <generated manifest>
#   5. Waits until it is healthy (up to 15 min).
#   6. Checks the restored data: row A must exist, row B must not.
#        kubectl cnpg psql pg-restore-test -n databases -- -d postgres -c "SELECT ..."
#   7. Cleanup (trap, also on failure or Ctrl+C): deletes pg-restore-test
#      (its pods, volumes and Secrets go with it) and drops the marker table in
#      the live cluster; shows that nothing named pg-restore-test is left.
#
# Output: PASS / FAIL / INFO lines with UTC times, also written to
# docs/evidence/07-f6-restore.txt. No secrets are printed.
#
# What you should see: row A present and row B absent in the restored cluster, the cleanup,
#   then "RESULT F6 passed".
# If it fails: the restore does not get healthy within 15 min: see the Troubleshooting
#   table in docs/runbooks/postgres-backup-restore.md; the trap still cleans up.
# Needs: kubectl with the cnpg plugin, jq.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=docs/evidence/07-f6-restore.txt
NS=databases
LIVE=pg-openbao
RESTORE=pg-restore-test
IMAGE=$(kubectl -n "$NS" get cluster "$LIVE" -o jsonpath='{.spec.imageName}')
FAILS=0

ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }
# kubectl cnpg psql runs psql through a terminal, which ends lines with a
# carriage return: strip it, or it ends up inside values (first F6 run: an
# invalid targetTime "...Z\r").
sql()  { local c=$1; shift; kubectl cnpg psql "$c" -n "$NS" -- -d postgres -tA -c "$*" | tr -d '\r'; }
phase() { kubectl -n "$NS" get cluster "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }

echo "==> 1. Start state"
echo "live cluster: $(phase "$LIVE"), ready $(kubectl -n "$NS" get cluster "$LIVE" -o jsonpath='{.status.readyInstances}')"
[[ "$(phase "$LIVE")" == *healthy* ]] || { echo "live cluster not healthy: run scripts/checks/test-gate.sh first"; exit 1; }
kubectl -n "$NS" get cluster "$RESTORE" >/dev/null 2>&1 && { echo "$RESTORE already exists: delete it first"; exit 1; }
echo "backups (SCHEDULED-BY empty = by hand or from Git):"
kubectl -n "$NS" get backup --sort-by=.metadata.creationTimestamp \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STOPPED:.status.stoppedAt,SCHEDULED-BY:.metadata.labels.cnpg\\.io/scheduled-backup

read -r -p "This writes 2 test rows into $LIVE (database postgres) and creates the temporary cluster $RESTORE. Continue? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "aborted, nothing changed"; exit 1; }

cleanup() {
  info "cleanup: deleting cluster $RESTORE and the marker table in $LIVE"
  kubectl -n "$NS" delete cluster "$RESTORE" --ignore-not-found --timeout=180s >/dev/null 2>&1 || info "cleanup: delete of $RESTORE did not finish, check: kubectl -n $NS get cluster,pod,pvc"
  sql "$LIVE" "DROP TABLE IF EXISTS f6_marker" >/dev/null 2>&1 || info "cleanup: could not drop f6_marker in $LIVE"
  sleep 10
  LEFT=$(kubectl -n "$NS" get cluster,pod,pvc,secret,job -o name 2>/dev/null | grep "$RESTORE" || true)
  [[ -z "$LEFT" ]] && info "cleanup: nothing named $RESTORE left" || { info "cleanup: still there (may need a minute):"; echo "$LEFT"; }
}
trap cleanup EXIT

exec > >(tee "$OUT") 2>&1
echo "# F6: restore from backup (point-in-time recovery)   $(date -u +%Y-%m-%d)"
echo "# Command: bash scripts/failure-tests/failure-f6-restore.sh"
echo
SCHED=$(kubectl -n "$NS" get backup -l cnpg.io/scheduled-backup=pg-openbao-daily -o name 2>/dev/null | wc -l)
(( SCHED > 0 )) && pass "scheduled backups from pg-openbao-daily: $SCHED" \
                || info "no backup from the daily schedule yet (slot 12:00 UTC; a missed slot runs when the operator runs again)"
LAST=$(kubectl -n "$NS" get backup -o json | jq -r '[.items[] | select(.status.phase=="completed")] | sort_by(.status.stoppedAt) | last | "\(.metadata.name) stopped \(.status.stoppedAt)"')
info "newest completed base backup: $LAST"

echo
echo "==> 3. Marker rows in $LIVE (database postgres)"
sql "$LIVE" "CREATE TABLE IF NOT EXISTS f6_marker (id int PRIMARY KEY, note text, at timestamptz DEFAULT now())" >/dev/null
sql "$LIVE" "INSERT INTO f6_marker (id, note) VALUES (1, 'row A: before the target time')" >/dev/null
info "row A written at $(sql "$LIVE" "SELECT at AT TIME ZONE 'UTC' FROM f6_marker WHERE id = 1")"
sleep 5
TARGET=$(sql "$LIVE" "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
info "target time (restore up to here): $TARGET"
sleep 5
sql "$LIVE" "INSERT INTO f6_marker (id, note) VALUES (2, 'row B: after the target time')" >/dev/null
info "row B written at $(sql "$LIVE" "SELECT at AT TIME ZONE 'UTC' FROM f6_marker WHERE id = 2")"
WAL=$(sql "$LIVE" "SELECT pg_walfile_name(pg_switch_wal())")
info "WAL switched; waiting until $WAL is archived in S3"
ARCHIVED=""
for _ in $(seq 24); do   # up to 2 minutes
  LASTWAL=$(sql "$LIVE" "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver")
  [[ -n "$LASTWAL" && ! "$LASTWAL" < "$WAL" ]] && { ARCHIVED=yes; break; }
  sleep 5
done
[[ -n "$ARCHIVED" ]] && pass "WAL up to $WAL archived (last archived: $LASTWAL)" || fail "WAL $WAL not archived after 2 min (last: ${LASTWAL:-none})"
info "live cluster has: $(sql "$LIVE" "SELECT string_agg(id || '=' || note, '; ' ORDER BY id) FROM f6_marker")"

echo
echo "==> 4. Restore cluster $RESTORE up to $TARGET (temporary, not in Git)"
T0=$(date +%s)
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $RESTORE
  namespace: $NS
spec:
  instances: 1
  imageName: $IMAGE
  storage:
    size: 5Gi
    storageClass: standard
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {memory: 512Mi}
  postgresql:
    parameters:
      shared_buffers: "128MB"
  bootstrap:
    recovery:
      source: pg-openbao-backup
      recoveryTarget:
        targetTime: "$TARGET"
      database: openbao
      owner: openbao
  externalClusters:
    - name: pg-openbao-backup
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-backups
          serverName: pg-openbao
EOF

echo
echo "==> 5. Wait until $RESTORE is healthy (up to 15 min)"
OK=""
while (( $(date +%s) - T0 < 900 )); do
  [[ "$(phase "$RESTORE")" == *healthy* ]] && { OK=yes; break; }
  (( ($(date +%s) - T0) % 60 < 10 )) && info "t+$(( $(date +%s) - T0 ))s phase: $(phase "$RESTORE")"
  sleep 10
done
kubectl -n "$NS" get pods -l cnpg.io/cluster="$RESTORE" -o wide
[[ -n "$OK" ]] && pass "$RESTORE healthy after $(( $(date +%s) - T0 )) s" || fail "$RESTORE not healthy after 15 min (phase: $(phase "$RESTORE"))"

echo
echo "==> 6. Restored data"
if [[ -n "$OK" ]]; then
  ROWS=$(sql "$RESTORE" "SELECT string_agg(id::text, ',' ORDER BY id) FROM f6_marker" 2>&1 || true)
  info "rows in $RESTORE: ${ROWS:-none}"
  [[ "$ROWS" == 1 ]] && pass "row A exists and row B does not: restored exactly to $TARGET" \
                     || fail "expected only row 1, got: ${ROWS:-none}"
  info "databases in $RESTORE: $(sql "$RESTORE" "SELECT string_agg(datname, ', ') FROM pg_database WHERE NOT datistemplate")"
fi

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  F6 passed" || { echo "$(ts) RESULT  F6: $FAILS check(s) failed"; exit 1; }
