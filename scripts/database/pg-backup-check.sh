#!/usr/bin/env bash
# pg-backup-check.sh - shows the backup schedule and the last backup, then takes a manual base backup.
#
# In plain words:
#   PostgreSQL makes a full copy of its data (a base backup) every day at
#   12:00 UTC and sends it to the S3 storage. This script shows whether that
#   works: when the schedule last ran and will run next, how old the last good
#   backup is, and the list of all backups. A backup that was missed while the
#   Codespace was stopped runs late by itself (risk R06).
#
#   Then it takes one backup by hand and waits until it is completed, to prove
#   the whole path works right now. That backup is the only thing it changes.
#   Two NetworkPolicy tests run this script to prove that PostgreSQL can still
#   reach the storage.
#
# Run it: bash scripts/database/pg-backup-check.sh (after a backup change; risk R06; netpol-test-storage.sh and netpol-test-databases.sh run it)
# Changes the cluster: yes: takes one base backup of pg-openbao (a Backup object
#   outside Git; a record of an action, not configuration). Prints no secrets.
#
# What it does:
#   1. Applies Git now.
#        flux reconcile source git flux-system
#        flux reconcile kustomization apps-database
#   2. Shows the ScheduledBackup (schedule, last and next run) and the age of the
#      last completed base backup.
#        kubectl -n databases get scheduledbackup pg-openbao-daily -o jsonpath=...
#   3. Lists all backups; SCHEDULED-BY is empty for backups taken by hand or by Git.
#        kubectl -n databases get backup --sort-by=.metadata.creationTimestamp
#   4. Shows the events of the ScheduledBackup.
#   5. Takes a manual base backup (same command as
#      docs/runbooks/postgres-backup-restore.md, section 2) and waits up to 5 min
#      until it is completed or failed.
#        kubectl cnpg backup pg-openbao -n databases --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io
#
# What you should see: "schedule=0 0 12 * * *", the last successful backup with
#   its age, then the new Backup with phase=completed.
# If it fails: phase=failed or no phase: kubectl cnpg status pg-openbao -n
#   databases ("Working WAL archiving") and the Troubleshooting table in
#   docs/runbooks/postgres-backup-restore.md.
# Needs: flux, kubectl with the cnpg plugin, jq.
set -euo pipefail

NS=databases

echo "==> Flux: fetch Git and apply apps-database"
flux reconcile source git flux-system
flux reconcile kustomization apps-database

# last_completed: name, stop time and age of the newest completed Backup
last_completed() {
  kubectl -n "$NS" get backup -o json | jq -r '
    [.items[] | select(.status.phase == "completed")] | sort_by(.status.stoppedAt) | last
    | if . == null then "no completed backup"
      else "\(.metadata.name) stopped=\(.status.stoppedAt) age=\((now - (.status.stoppedAt | fromdateiso8601)) / 3600 | floor)h\((now - (.status.stoppedAt | fromdateiso8601)) % 3600 / 60 | floor)m"
      end'
}

echo
echo "==> ScheduledBackup (times in UTC)"
kubectl -n "$NS" get scheduledbackup pg-openbao-daily \
  -o jsonpath='schedule={.spec.schedule} lastCheck={.status.lastCheckTime} lastSchedule={.status.lastScheduleTime} nextSchedule={.status.nextScheduleTime}{"\n"}'
echo "last successful base backup: $(last_completed)"
echo
echo "==> All backups (SCHEDULED-BY empty = taken by hand or by Git)"
kubectl -n "$NS" get backup --sort-by=.metadata.creationTimestamp \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STOPPED:.status.stoppedAt,SCHEDULED-BY:.metadata.labels.cnpg\\.io/scheduled-backup
echo
echo "==> Events of the ScheduledBackup"
kubectl -n "$NS" get events --field-selector involvedObject.name=pg-openbao-daily \
  -o custom-columns=TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message || true

echo
echo "==> Manual base backup"
kubectl cnpg backup pg-openbao -n "$NS" --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io
sleep 2
BACKUP=$(kubectl -n "$NS" get backup --sort-by=.metadata.creationTimestamp -o name | tail -1)
for _ in $(seq 60); do
  phase=$(kubectl -n "$NS" get "$BACKUP" -o jsonpath='{.status.phase}')
  [[ "$phase" == completed || "$phase" == failed ]] && break
  sleep 5
done
kubectl -n "$NS" get "$BACKUP" -o jsonpath='{.metadata.name} phase={.status.phase} started={.status.startedAt} stopped={.status.stoppedAt}{"\n"}'
echo "last successful base backup now: $(last_completed)"
