#!/usr/bin/env bash
# Hardening A1 (risk R06): after `git push`, applies the new backup schedule,
# shows it, shows the age of the last successful base backup, then takes a
# manual base backup (same command as docs/runbooks/postgres-backup-restore.md)
# and waits until it is completed. Prints no secrets.
#   bash scripts/database/pg-backup-check.sh
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
