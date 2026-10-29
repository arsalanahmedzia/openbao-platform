# Scripts

Every script explains at the top what it does, step by step, with the real
commands. They print PASS / FAIL / INFO lines with UTC times and never print
keys or tokens. Run them from the repository root, for example
`bash scripts/verify/test-gate.sh`. Scripts for daily use are listed in
[`docs/operations.md`](../docs/operations.md); failure tests in
[`docs/runbooks/failure-tests.md`](../docs/runbooks/failure-tests.md).

## Start the platform, full order

The README shows the five main commands. This is the full order, as it was
used (demo environment: a GitHub Codespace, see `docs/environment.md`).

```bash
# in a Codespace created from this repo (tools install automatically);
# secrets SOPS_AGE_KEY, FLUX_GITHUB_TOKEN, GITHUB_USER set as Codespaces secrets
bash scripts/setup/bootstrap.sh                       # kind + SOPS key + Flux
flux get kustomizations --watch
```

OpenBao (once Flux shows `apps-openbao` Ready; details in
`docs/runbooks/openbao-init-unseal.md`):

```bash
bash scripts/openbao/openbao-deploy-check.sh          # 3 pods Running, sealed, tables in PostgreSQL
bash scripts/openbao/openbao-init.sh                  # once: keys to ~/openbao-init.json + Codespaces secrets
bash scripts/after-restart/openbao-unseal.sh          # after every pod/Codespace restart
bash scripts/openbao/openbao-configure.sh             # once: KV v2, Kubernetes auth, ESO policies and role
bash scripts/openbao/openbao-evidence.sh              # evidence in docs/evidence/04-*.txt
bash scripts/failure-tests/openbao-failover-test.sh   # deletes the active pod (asks first)
```

Check everything (read-only; includes monitoring: targets up, alert rules
loaded, nothing firing; details in `docs/runbooks/monitoring.md`):

```bash
bash scripts/verify/test-gate.sh
bash scripts/monitoring/monitoring-check.sh
```

## Folders

### setup/ (once, at the start)

| Script | What it does | Changes |
| --- | --- | --- |
| [`install-tools.sh`](setup/install-tools.sh) | Installs docker, kubectl, kind, flux, sops, age and other tools on Ubuntu 24.04; the devcontainer runs it when a Codespace is created | the host |
| [`bootstrap.sh`](setup/bootstrap.sh) | Creates the kind cluster from [`kind-config.yaml`](setup/kind-config.yaml), the Secret `sops-age`, and runs `flux bootstrap` | the cluster |
| [`pin-versions.sh`](setup/pin-versions.sh) | Looks up the newest stable chart versions and writes them into the HelmReleases | repo files |
| [`s3-secrets.sh`](setup/s3-secrets.sh) | Generates the S3 keys and writes the two SOPS files | repo files |
| [`openbao-db-secret.sh`](setup/openbao-db-secret.sh) | Generates the OpenBao database password and writes the two SOPS files (`--force` to rotate) | repo files |
| [`sops-demo.sh`](setup/sops-demo.sh) | Writes the encrypted demo Secret and adds it to `infra-configs`; prints the git command, does not run it | repo files |

### after-restart/ (after a Codespace or pod restart)

| Script | What it does | Changes |
| --- | --- | --- |
| [`resume.sh`](after-restart/resume.sh) | Starts the kind nodes, re-adds the firewall rule, checks DNS, runs `kind-fix-pod-network.sh` | the cluster |
| [`kind-fix-pod-network.sh`](after-restart/kind-fix-pod-network.sh) | Repairs pod IPs after a node IP change: restarts kindnet, recreates affected pods (asks first) | the cluster |
| [`openbao-unseal.sh`](after-restart/openbao-unseal.sh) | Unseals every sealed OpenBao pod with 3 key shares via stdin; skips unsealed pods | the cluster |

### verify/ (read-only, any time)

| Script | What it does | Changes |
| --- | --- | --- |
| [`test-gate.sh`](verify/test-gate.sh) | Checks Flux, OpenBao, PostgreSQL, External Secrets and monitoring; ends with `GATE PASSED` | nothing (asks Flux to fetch Git) |
| [`github-access.sh`](verify/github-access.sh) | Shows token types, scopes, deploy keys and branch protection through the GitHub API | nothing |

### openbao/

| Script | What it does | Changes |
| --- | --- | --- |
| [`openbao-deploy-check.sh`](openbao/openbao-deploy-check.sh) | Reconciles and shows the 3 OpenBao pods running and sealed | Flux reconcile only |
| [`openbao-init.sh`](openbao/openbao-init.sh) | Initialises OpenBao once; stores the 5 shares and the root token without printing them | the cluster |
| [`openbao-configure.sh`](openbao/openbao-configure.sh) | KV v2, Kubernetes auth, policies, roles, test secret (root token) | the cluster |
| [`openbao-policy-update.sh`](openbao/openbao-policy-update.sh) | Applies the policy files and proves the push rights as the ESO login | the cluster |
| [`openbao-tls-rollout.sh`](openbao/openbao-tls-rollout.sh) | Reconciles, then restarts outdated OpenBao pods one by one and unseals them | pod restarts |
| [`openbao-audit-check.sh`](openbao/openbao-audit-check.sh) | Rolls the pods onto the audit config and shows one audit entry with hashed values | pod restarts |
| [`openbao-evidence.sh`](openbao/openbao-evidence.sh) | Writes pods, status, HTTPS and PostgreSQL evidence to `docs/evidence/04-*` | nothing |
| [`openbao-generate-root.sh`](openbao/openbao-generate-root.sh) | New root token from 3 shares, stored as a Codespaces secret (untested) | OpenBao, Codespaces secret |
| [`openbao-revoke-root.sh`](openbao/openbao-revoke-root.sh) | Revokes the root token, checks it is refused, offers to delete the secret | OpenBao |

### external-secrets/

| Script | What it does | Changes |
| --- | --- | --- |
| [`eso-store-check.sh`](external-secrets/eso-store-check.sh) | Reconciles and shows whether the store is Valid | Flux reconcile only |
| [`eso-pull-check.sh`](external-secrets/eso-pull-check.sh) | Reconciles and shows the pulled value | Flux reconcile only |
| [`eso-refresh-test.sh`](external-secrets/eso-refresh-test.sh) | Changes `secret/demo/hello` as demo-writer, waits for the sync, restores it | a demo value, restored |
| [`eso-push-check.sh`](external-secrets/eso-push-check.sh) | Reconciles and reads the pushed value back as the ESO login | Flux reconcile only |
| [`eso-evidence.sh`](external-secrets/eso-evidence.sh) | Collects all ESO evidence into `05-external-secrets.txt`; runs the refresh test | a demo value, restored |
| [`eso-debug.sh`](external-secrets/eso-debug.sh) | Shows conditions, events and log lines of an ESO object | nothing |

### database/ (PostgreSQL and its backups)

| Script | What it does | Changes |
| --- | --- | --- |
| [`pg-backup-check.sh`](database/pg-backup-check.sh) | Shows the backup schedule and the last backup, then takes a manual base backup | a new backup |
| [`pg-check.sh`](database/pg-check.sh) | Checks 3 ready instances, the roles, streaming to both replicas, and that a row written on the primary reaches every replica | a test table in database `postgres`, dropped again |
| [`storage-check.sh`](database/storage-check.sh) | Checks SeaweedFS, the bucket job and an S3 round trip from namespace `databases`; counts the backup files | a temporary pod and test file, deleted again |

### monitoring/

Daily, read-only (`test-gate.sh` also runs it):

| Script | What it does | Changes |
| --- | --- | --- |
| [`monitoring-check.sh`](monitoring/monitoring-check.sh) | Health check of monitoring through port-forwards: every scrape target up/down, the 8 platform alert rules loaded and healthy, pending/firing alerts in Prometheus and Alertmanager. A firing alert is a FAIL. `--wait-firing <Alert> [minutes]` waits until that alert fires (for failure tests). | nothing |

Run these again only when you change that part of monitoring (they were written for the stages M1 to M3):

| Script | What it does | Changes |
| --- | --- | --- |
| [`monitoring-deploy-check.sh`](monitoring/monitoring-deploy-check.sh) | M1: reconciles the layer `apps-monitoring`, waits for Prometheus, Alertmanager, operator and kube-state-metrics to be Ready, checks the volume, shows memory requests/limits. | Flux reconcile only |
| [`monitoring-openbao-metrics.sh`](monitoring/monitoring-openbao-metrics.sh) | M2: rolls out the OpenBao metrics listener (restarts and unseals the pods one by one via `openbao-tls-rollout.sh`), reads the metrics over HTTPS verified with the demo CA, checks plain HTTP and Traefik give no metrics, shows Prometheus' scrape config. | OpenBao pod restarts |
| [`monitoring-cnpg-metrics.sh`](monitoring/monitoring-cnpg-metrics.sh) | M2: applies the PostgreSQL PodMonitor, reads the primary's metrics (port 9187), shows the metrics the alerts use (backup timestamps, replication). | Flux reconcile only |
| [`monitoring-eso-metrics.sh`](monitoring/monitoring-eso-metrics.sh) | M2: applies the ESO metrics TLS change (controller restarts once), reads the metrics over HTTPS verified with the demo CA, checks plain HTTP gives none, checks the scrape config and that the target is up. | ESO controller restart |
| [`monitoring-netpol-check.sh`](monitoring/monitoring-netpol-check.sh) | M3: applies the `allow-prometheus-metrics` NetworkPolicies and probes ports 9101/9187/8080 with temporary busybox pods (open only from Prometheus' label in `monitoring`), then waits until every target is up. | temporary probe pods (deleted) |

### hardening/ (NetworkPolicy tests)

| Script | What it does | Changes |
| --- | --- | --- |
| [`netpol-enforcement-test.sh`](hardening/netpol-enforcement-test.sh) | Proves NetworkPolicies are enforced in a temporary namespace, deleted afterwards | temporary namespace |
| [`netpol-test-storage.sh`](hardening/netpol-test-storage.sh) | Proves the rules of `storage`; runs `pg-backup-check.sh` | temporary pods, a backup |
| [`netpol-test-databases.sh`](hardening/netpol-test-databases.sh) | Proves the rules of `databases`; runs `pg-backup-check.sh` | temporary pods, a backup |
| [`netpol-test-openbao.sh`](hardening/netpol-test-openbao.sh) | Proves the rules of `openbao`, including an ESO login on a standby | temporary pods |
| [`netpol-test-external-secrets.sh`](hardening/netpol-test-external-secrets.sh) | Proves the webhook path with a dry-run create and the blocked ports | temporary pods |
| [`netpol-test-eso-demo.sh`](hardening/netpol-test-eso-demo.sh) | Proves the default-deny of `eso-demo` with a temporary server pod; runs the refresh test | temporary pods |

### failure-tests/ (break something on purpose, ask first)

| Script | What it breaks |
| --- | --- |
| [`failure-f1-worker.sh`](failure-tests/failure-f1-worker.sh) | Stops a worker node; restarts it, runs the pod-network fix and the unseal |
| [`failure-f2-postgres.sh`](failure-tests/failure-f2-postgres.sh) | Deletes the PostgreSQL primary and measures the write outage |
| [`failure-f3-sealed.sh`](failure-tests/failure-f3-sealed.sh) | Restarts all OpenBao pods (sealed), watches ESO, unseals |
| [`failure-f4-pushsecret.sh`](failure-tests/failure-f4-pushsecret.sh) | Suspends Flux, deletes the PushSecret, resumes |
| [`failure-f5-eso-restart.sh`](failure-tests/failure-f5-eso-restart.sh) | Deletes the ESO controller pod and proves the new login in the audit log |
| [`failure-f6-restore.sh`](failure-tests/failure-f6-restore.sh) | Point-in-time restore into a temporary cluster, then cleans up |
| [`openbao-failover-test.sh`](failure-tests/openbao-failover-test.sh) | Deletes the active OpenBao pod, waits for a standby, unseals the new pod |

Proving an alert: `failure-f3-sealed.sh` takes `F3_WATCH_ROUNDS` (15 s rounds
before the unseal, default 8) and `F3_OUT` (evidence file); see
`docs/runbooks/monitoring.md`, section 5.

## Old paths

Until 2026-10-29 all scripts were directly in `scripts/`. The `Command:` lines
in `docs/evidence/` are recorded outputs and keep the old paths. Each old path
`scripts/<name>` is now `scripts/<folder>/<name>`:

| Folder | Scripts |
| --- | --- |
| `setup/` | install-tools, bootstrap, kind-config.yaml, pin-versions, s3-secrets, openbao-db-secret, sops-demo |
| `after-restart/` | resume, kind-fix-pod-network, openbao-unseal |
| `verify/` | test-gate, github-access-check (now named github-access.sh) |
| `openbao/` | openbao-deploy-check, openbao-init, openbao-configure, openbao-policy-update, openbao-tls-rollout, openbao-audit-check, openbao-evidence, openbao-generate-root, openbao-revoke-root |
| `external-secrets/` | eso-store-check, eso-pull-check, eso-refresh-test, eso-push-check, eso-evidence, eso-debug |
| `database/` | pg-backup-check (new on 2026-10-29: pg-check, storage-check) |
| `monitoring/` | monitoring-check, monitoring-deploy-check, monitoring-openbao-metrics, monitoring-cnpg-metrics, monitoring-eso-metrics, monitoring-netpol-check |
| `hardening/` | netpol-enforcement-test, netpol-test-storage, netpol-test-databases, netpol-test-openbao, netpol-test-external-secrets, netpol-test-eso-demo |
| `failure-tests/` | failure-f1-worker … failure-f6-restore, openbao-failover-test |
