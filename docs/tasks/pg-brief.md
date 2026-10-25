# Task: HA PostgreSQL with CloudNativePG, backups to S3, restore test

Read CLAUDE.md first and follow its rules (plain, detailed explanations; no analogies; never
print secrets; ask before anything destructive; everything through Git/Flux; pin versions).
Work like the S3 stage: explain each file BEFORE creating it, small commits, evidence files.
Look at how docs/tasks/s3-brief.md was done and keep the same structure and quality.

## Why
OpenBao (next stage) stores its data in PostgreSQL. This database must survive a node failure
and must be restorable to a point in time. CloudNativePG runs PostgreSQL; the Barman Cloud
plugin ships base backups and WAL (transaction logs) to the S3 bucket `pg-backups`.
Already installed by Flux: CloudNativePG operator and plugin-barman-cloud (namespace
cnpg-system), cert-manager (the plugin needs it), S3 service `seaweedfs.storage.svc:8333`,
bucket `pg-backups`, Secret `databases/s3-credentials` (keys ACCESS_KEY_ID, ACCESS_SECRET_KEY).

## Design (decided, ask before changing)
- Namespace `databases` already exists. The layers follow CLAUDE.md: infra-controllers -> infra-configs -> (infra-storage) -> apps.
  Create the folder `apps/database/`
  and a Flux Kustomization `apps-database` in `clusters/demo/` with `dependsOn: infra-storage`,
  `wait: true`, `timeout: 15m`, and the SOPS decryption block like the other layers.
- Objects:
  1. `ObjectStore` (barmancloud.cnpg.io) named `pg-backups` in `databases`: destinationPath
     `s3://pg-backups/`, endpointURL `http://seaweedfs.storage.svc:8333`, credentials from
     Secret `s3-credentials`, WAL and data compression (gzip is fine), retentionPolicy 7d.
  2. `Cluster` (postgresql.cnpg.io) named `pg-openbao`: instances 3, one per worker node
     (pod anti-affinity / topology spread on hostname, enforced, not preferred), storage 5Gi,
     database `openbao`, owner `openbao`, the plugin entry for barman-cloud with
     `isWALArchiver: true`, and resource requests small enough for a 16 GB Codespace
     (about 256Mi request, 512Mi limit per instance; verify the cluster stays stable).
  3. `ScheduledBackup` every day (method: plugin) plus ONE immediate `Backup` object for the test.
  4. Database credentials: CloudNativePG generates the app Secret `pg-openbao-app` itself.
     Do NOT create a hand-written password unless needed; if a SOPS secret is required, say why.
- Keep the demo small. Plain HTTP to S3 inside the cluster (see ADR 0002).

## Things you MUST verify (do not guess; say when unsure)
1. Installed CRD versions and field names: `kubectl explain objectstores.barmancloud.cnpg.io.spec`
   and `--recursive`, `kubectl explain clusters.postgresql.cnpg.io.spec.plugins`,
   `...spec.bootstrap.recovery`, `...spec.externalClusters`, `kubectl explain backups...spec`,
   `scheduledbackups...spec`. Use `kubectl get crd | grep -i cnpg\|barman`.
2. PostgreSQL image: let the operator's default image catalog choose, or pin a specific
   exact PostgreSQL major.minor tag that exists. Verify it can be pulled (`docker pull`).
   Do not use `latest`.
3. The plugin must be running: `kubectl -n cnpg-system get pods`; check the plugin's own docs
   shipped with the chart or its repo for the Cluster `plugins:` syntax and the ObjectStore fields.
4. The S3 service name/port and that a path-style endpoint works with the Barman Cloud tool
   (SeaweedFS needs path-style addressing; check how to express this).

## Delivery and verification
- Commit, push, `flux reconcile kustomization flux-system --with-source`, then show:
  `flux get kustomizations`, `kubectl -n databases get cluster,pods -o wide`
  (3 instances on 3 DIFFERENT nodes, one primary, two replicas), `kubectl cnpg status pg-openbao -n databases`,
  `kubectl -n databases get objectstore,backup,scheduledbackup`.
- Prove backups: the immediate Backup reaches phase `completed`; objects appear in the bucket
  (list with the verified AWS CLI image from a throwaway pod, then delete that pod; say it was manual).
- Prove replication: create a table with a few rows on the primary (via `kubectl cnpg psql` or exec),
  read the same rows from a replica.
- Failover test: `kubectl delete pod <primary>` then show a replica promoted and the cluster healthy
  again. (The Docker-level node failure test is a later stage; do not stop nodes now.)
- Restore test (point-in-time): insert row A, note the time (UTC), wait ~1 minute, insert row B,
  force a WAL switch (`SELECT pg_switch_wal();`), then create a NEW Cluster `pg-restore` in `databases`
  that bootstraps from the backup with `recoveryTarget.targetTime` between A and B. Show that
  `pg-restore` has row A but not row B. Keep the restore manifest in Git under
  `docs/runbooks/restore-example.yaml` (NOT in the Flux path), so Flux does not create it by itself.
  Delete the test cluster afterwards and say so.
- Evidence files: docs/evidence/03-cluster.txt, 03-backup.txt, 03-replication.txt, 03-failover.txt,
  03-restore.txt. Runbook: docs/runbooks/postgres-backup-restore.md (steps, in order, with
  expected output). ADR docs/adr/0003-cloudnativepg-ha.md (why 3 instances, anti-affinity,
  backup method, trade-offs: single S3 pod, RPO from WAL archiving interval, demo sizing).
- Append to docs/time-log.md. Then list 5 plain sentences the user should be able to explain.
