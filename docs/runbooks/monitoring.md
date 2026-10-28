# Runbook: monitoring and alerts

## What it is

Prometheus collects numbers (metrics) from OpenBao, PostgreSQL and External
Secrets every 30 s and checks 8 alert rules. When a rule is true for long
enough, the alert fires and Alertmanager shows it.

Prometheus, Alertmanager, the Prometheus Operator and kube-state-metrics run in
namespace `monitoring` (Flux layer `apps-monitoring`, folder
`apps/monitoring/`). Design: [ADR 0007](../adr/0007-monitoring.md). Tested on
2026-10-28, evidence in `docs/evidence/08-monitoring.txt`.
Words are explained in the [glossary](../glossary.md).

## Why we need it

The failure tests showed failures nobody would notice: a sealed OpenBao (F3),
a lost node (F1), a late backup (R06). Without alerts they stay hidden until a
secret is missing.

## The picture

The dotted arrows in the README picture ([`how-it-runs.png`](../images/how-it-runs.png),
shown in the [README](../../README.md#in-60-seconds)) are monitoring:
Prometheus measures OpenBao, PostgreSQL and ESO. How to read it: an arrow
points from the one who starts the call to the one who is asked.

How Prometheus knows what to measure: a PodMonitor is a Kubernetes object
that names the pods and the port to read. There is one per target in
`apps/monitoring/`. (A ServiceMonitor does the same through a Kubernetes
Service; it is not used here.)

## Step by step

### 1. What is watched

| Target (Prometheus job) | Pods | Port | Transport |
| --- | --- | --- | --- |
| `monitoring/openbao` | `openbao-0/1/2` | 9101, path `/v1/sys/metrics?format=prometheus` | HTTPS, verified with the demo CA, name `openbao.openbao.svc` |
| `monitoring/pg-openbao` | `pg-openbao-1/2/3` | 9187 `/metrics` | plain HTTP (known gap R30) |
| `monitoring/external-secrets` | ESO controller | 8080 `/metrics` | HTTPS, verified with the demo CA, name `external-secrets-metrics.external-secrets.svc` |
| `kube-state-metrics` | kube-state-metrics | 8080 | HTTP, inside `monitoring` (state of pods and nodes) |
| Prometheus, Alertmanager, operator | themselves | | HTTP, inside `monitoring` |

Only the Prometheus pod may reach 9101, 9187 and 8080 (NetworkPolicy
`allow-prometheus-metrics` in each namespace). No Alertmanager receiver is
configured: alerts are only visible, nothing is sent.

### 2. Check everything

```bash
bash scripts/monitoring-check.sh
```

Read-only. Expected: `PASS all 13 targets up`, 8 × `PASS rule ... health ok`,
`PASS no firing alerts`, `RESULT monitoring check passed`. A firing alert is
a FAIL and is listed with its summary. Right after a rule change the script
waits up to 2 minutes for the rules to load.

### 3. Open the UIs

There is no Ingress for monitoring. Use a port-forward (VS Code / Codespaces
forwards the port to your browser):

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/alerts   rules and their state
# http://localhost:9090/targets  scrape targets, last error
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093          alerts Alertmanager received
```

Ctrl+C ends the port-forward.

### 4. Alerts: meaning and what to do

**OpenBaoSealed** (critical, 2 min). A pod reports `vault_core_unsealed 0` or
is not Ready (its readiness check is `bao status`). A sealed pod serves no
secrets; if all are sealed, ESO cannot sync.
1. `kubectl -n openbao get pods -L openbao-active,openbao-sealed`
2. Sealed: `bash scripts/openbao-unseal.sh` (keys from the Codespaces secrets,
   never printed). See [openbao-init-unseal.md](openbao-init-unseal.md).
3. Not sealed but not Ready (crash loop): `kubectl -n openbao logs <pod>`;
   after a Codespace restart see R27 (`scripts/resume.sh`).

**ExternalSecretNotReady / PushSecretNotReady** (warning, 5 min). The object
could not sync. The Kubernetes Secret keeps its last value.
1. `bash scripts/eso-debug.sh`, or
   `kubectl -n <namespace> describe externalsecret|pushsecret <name>`.
2. Usually OpenBao is sealed or unreachable (then OpenBaoSealed fires too) or a
   policy denies the path ([external-secrets.md](external-secrets.md)).

**ClusterSecretStoreNotReady** (critical, 5 min). ESO cannot use the store
(the STATUS column is not `Valid`): login or configuration fails, nothing
syncs. `kubectl describe clustersecretstore openbao`. Seen during the M6 test
after 142 s with OpenBao sealed (`InvalidProviderConfig`); it recovered by
itself 9 s after the unseal.

**ExternalSecretsControllerDown** (critical, 5 min). Prometheus cannot scrape
the ESO controller: either the controller is down (no syncs) or the scrape
fails (then the three ESO alerts above cannot fire).
1. `kubectl -n external-secrets get pods`
2. Pod running: look at the target's last error (section 3, `/targets`). A
   certificate error means the controller fell back to a self-signed
   certificate: check that Secret `external-secrets/external-secrets-metrics-tls`
   exists and restart the controller (`kubectl -n external-secrets rollout
   restart deploy/external-secrets`).

**PostgresNotHealthy** (critical, 5 min). Fewer than 3 PostgreSQL instances
are up, or none is primary. OpenBao keeps all its data there.
1. `kubectl cnpg status pg-openbao -n databases`
2. See [postgres-backup-restore.md](postgres-backup-restore.md) and the
   failover notes in [failure-tests.md](failure-tests.md) (F2: a deleted
   primary waits up to 180 s, R28).

**BackupFailedOrTooOld** (warning, 15 min). No successful backup for 26 hours
(the schedule is daily at 12:00 UTC), or the last backup failed, or the backup
metric is missing.
1. `kubectl -n databases get backups` and `kubectl cnpg status pg-openbao -n databases`
   (line "Last Successful Backup", "Working WAL archiving").
2. Start a backup by hand: section 2 of [postgres-backup-restore.md](postgres-backup-restore.md).
   After a stopped Codespace a missed slot runs late by itself (R06).

**NodeNotReady** (critical, 2 min). A node has not been Ready for 2 minutes.
Its pods are not moved (no spare node, R16).
1. `kubectl get nodes`; in kind: `docker ps -a` (a stopped node container).
2. `docker start <node>`, then `bash scripts/resume.sh`; OpenBao pods on it
   come back sealed (`bash scripts/openbao-unseal.sh`).

### 5. Prove that an alert fires

Done on 2026-10-28 (M6): the sealed test with a longer sealed time.

```bash
# terminal 1 (watches, read-only)
bash scripts/monitoring-check.sh --wait-firing OpenBaoSealed 8
# terminal 2 (breaks and repairs; asks y/N)
F3_WATCH_ROUNDS=16 F3_OUT=docs/evidence/08-m6-f3-sealed.txt bash scripts/failure-f3-sealed.sh
```

Result: pending 22 s after the pods were deleted, firing after 2 min 22 s,
one alert per pod, received by Alertmanager; gone after the unseal.

## Example

A smoke detector waits a moment before it beeps, so steam from the kettle
does not set it off. Each alert here also waits ("for: 2m", "5m" or "15m")
before it fires, so a short normal hiccup (a failover, a restart) does not
raise an alarm.

## What can go wrong

- One Prometheus and one Alertmanager replica; all monitoring pods ran on one
  node. If that node fails, monitoring stops (R31).
- No receiver: nobody is notified. Look with `scripts/monitoring-check.sh`.
- Retention 2 days (max 1 GB on a 2 Gi volume).
- PostgreSQL metrics are plain HTTP (R30). Flux is not monitored here
  (`scripts/test-gate.sh` checks it).
- A new or changed alert rule shows "not loaded" right after a change: the
  rules need up to 1-2 minutes to reach Prometheus; `scripts/monitoring-check.sh`
  waits for them.
