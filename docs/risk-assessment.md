# Risk Assessment: OpenBao Platform

Date: 2026-10-26.

Scope: everything deployed from this repository (kind in a
GitHub Codespace, Flux, SOPS, cert-manager, Traefik, SeaweedFS, CloudNativePG,
OpenBao, External Secrets).

## 1. Threat Model

**What we protect**

| Asset | Where it lives |
| --- | --- |
| Secrets in OpenBao | PostgreSQL `pg-openbao` (encrypted by OpenBao) |
| Unseal key shares, root token | `~/openbao-init.json`, Codespaces secrets |
| PostgreSQL data and backups | PostgreSQL volumes, SeaweedFS (same cluster) |
| SOPS age key | Codespaces secret, Secret `flux-system/sops-age` |
| Git repository and GitHub token | GitHub, Codespaces secret `FLUX_GITHUB_TOKEN` |
| Demo root CA key | Secret `cert-manager/demo-root-ca` |

**Threats**

| Threat | Example |
| --- | --- |
| **Account compromise** | Someone gets into the GitHub account or a Codespace |
| **Pod compromise** | An attacker controls one pod and moves on in the cluster |
| **Host access** | Someone reads a node's disk or etcd |
| **Supply chain** | A changed chart or image is pulled |
| **Operator error** | A wrong Git change, lost keys, a forgotten step |
| **Infrastructure failure** | Pod, node or the whole Codespace stops |

**Trust boundaries:** GitHub → Flux → cluster · Codespace → cluster
(kubectl, keys) · Internet → Traefik → OpenBao · namespace ↔ namespace (pod
network) · OpenBao → PostgreSQL → S3.

## 2. Risk Matrix

Score = likelihood (L, 1-5) × impact (I, 1-5).
🔴 High 15-25 · 🟡 Medium 8-14 · 🟢 Low 1-7.

| Impact \ Likelihood | 1 Rare | 2 Unlikely | 3 Possible | 4 Likely | 5 Almost certain |
| --- | --- | --- | --- | --- | --- |
| **5 Severe** | 🟢 | 🟡 R02 R07 R08 R09 | 🔴 **R01 R04 R05** | 🔴 | 🔴 |
| **4 Major** | 🟢 R15 | 🟡 R13 R18 R19 R26 | 🟡 R12 | 🔴 | 🔴 |
| **3 Moderate** | 🟢 | 🟢 R10 R11 R14 R20 R21 R22 | 🟡 R17 | 🟡 R27 | 🔴 **R03** |
| **2 Minor** | 🟢 R30 | 🟢 R06 R24 R28 | 🟢 R16 R23 R29 R31 | 🟡 | 🟡 |
| **1 Negligible** | 🟢 R25 | 🟢 | 🟢 | 🟢 | 🟢 |

## 3. Risks

Status: **Open** · **Partly** mitigated · **Done** (mitigated) · **Accepted**.

| ID | Risk | Threat | L | I | Score | Status | Fix / Limitations |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R01 | All unseal keys and the root token in one place | Account compromise | 3 | 5 | 🔴 15 | Open | Revoke root (`openbao-revoke-root.sh`); auto-unseal |
| R03 | OpenBao sealed after every restart | Infrastructure failure | 5 | 3 | 🔴 15 | Accepted | Auto-unseal |
| R04 | All nodes on one Codespace VM | Infrastructure failure | 3 | 5 | 🔴 15 | Accepted | Nodes in 3 zones |
| R05 | Backups inside the same cluster | Infrastructure failure | 3 | 5 | 🔴 15 | Accepted | Off-cluster object storage |
| R12 | TLS renewal needs manual pod restarts | Operator error | 3 | 4 | 🟡 12 | Open | Automate restart; alert on cert age |
| R27 | Codespace restart can shuffle the kind node IPs; pods get IPs from another node's range, DNS and pod traffic fail, OpenBao crash-loops (seen 2026-10-28) | Infrastructure failure | 4 | 3 | 🟡 12 | Partly | `resume.sh` detects it; `kind-fix-pod-network.sh` repairs; real nodes keep their IPs |
| R02 | Losing the key shares loses all data | Operator error | 2 | 5 | 🟡 10 | Open | Test the off-Codespace copy |
| R07 | Flux prune can delete the database | Operator error | 2 | 5 | 🟡 10 | Accepted | Prune protection (decided against) |
| R08 | Git write = cluster admin; broad GitHub token | Account compromise | 2 | 5 | 🟡 10 | Open | Checklist in `docs/environment.md` |
| R09 | ESO may create tokens for any service account | Pod compromise | 2 | 5 | 🟡 10 | Open | Token rights only for ESO's account |
| R17 | OpenBao config not managed from Git | Operator error | 3 | 3 | 🟡 9 | Open | OpenTofu/Terraform provider |
| R13 | Demo root CA key in the cluster | Pod compromise | 2 | 4 | 🟡 8 | Accepted | Real PKI with offline root |
| R18 | Images pinned by tag, not digest/signature | Supply chain | 2 | 4 | 🟡 8 | Open | Digests and signature checks |
| R19 | One age key decrypts all SOPS secrets | Account compromise | 2 | 4 | 🟡 8 | Open | Break-glass key; KMS-backed SOPS |
| R26 | Kubernetes Secrets not encrypted at rest | Host access | 2 | 4 | 🟡 8 | Open | Encryption at rest (cluster rebuild) |
| R10 | Network access between namespaces | Pod compromise | 2 | 3 | 🟢 6 | Partly | Ingress policies done; egress open |
| R14 | Async replication can lose recent writes | Infrastructure failure | 2 | 3 | 🟢 6 | Accepted | Synchronous replication |
| R16 | No spare node for rescheduling | Infrastructure failure | 3 | 2 | 🟢 6 | Accepted | N+1 nodes |
| R20 | ESO may read all of `secret/` | Pod compromise | 2 | 3 | 🟢 6 | Open | Limit `eso-read` to needed paths |
| R21 | Deleting the PushSecret deletes the value | Operator error | 2 | 3 | 🟢 6 | Accepted | Review deletions |
| R22 | Tight memory limits | Infrastructure failure | 2 | 3 | 🟢 6 | Accepted | Load test, raise limits |
| R23 | Running OpenBao pods can differ from Git | Operator error | 3 | 2 | 🟢 6 | Partly | Rollout script; alert on drift |
| R29 | ESO controller and Flux source/helm controllers run as 1 replica: a lost node stops syncing for ~6 min (F1) | Infrastructure failure | 3 | 2 | 🟢 6 | Open | 2 replicas, or a shorter toleration for unreachable nodes |
| R11 | Failures go unnoticed (before 2026-10-28: no monitoring) | All | 2 | 3 | 🟢 6 | Partly | Prometheus + 8 alerts (ADR 0007), OpenBaoSealed proven in M6; no receiver, so alerts are only seen when someone looks (R31) |
| R31 | Monitoring is single: 1 Prometheus, 1 Alertmanager, all 4 monitoring pods were on worker3, no receiver | Infrastructure failure | 3 | 2 | 🟢 6 | Accepted | 2 replicas, a receiver (mail/on-call) and a watchdog alert checked from outside |
| R06 | Scheduled backup late while stopped | Infrastructure failure | 2 | 2 | 🟢 4 | Done | Runs on resume; 12:00 UTC slot |
| R15 | OpenBao does not verify PostgreSQL's certificate | Pod compromise | 1 | 4 | 🟢 4 | Open | `sslmode=verify-full` |
| R24 | One Traefik replica | Infrastructure failure | 2 | 2 | 🟢 4 | Accepted | 2+ replicas behind a load balancer |
| R28 | Deleting the PostgreSQL primary pod: failover waits up to 180 s for open connections (F2: 187 s) | Operator error | 2 | 2 | 🟢 4 | Accepted | Switchover first (`kubectl cnpg promote`); shorter `smartShutdownTimeout` |
| R30 | PostgreSQL metrics (port 9187) are plain HTTP: readable and changeable on the pod network. Known gap: CloudNativePG can only use PostgreSQL's server certificate for them, signed by the operator's own CA in `pg-openbao-ca` (Secret also holds `ca.key`), which a PodMonitor in `monitoring` cannot reference and which we do not want the Prometheus Operator to read (ADR 0007) | Pod compromise | 1 | 2 | 🟢 2 | Accepted | NetworkPolicy: only the Prometheus pod may connect. Production fix: PostgreSQL server certificate from cert-manager/demo CA (`spec.certificates.serverTLSSecret`, `serverCASecret`), then `spec.monitoring.tls.enabled: true` (rolls all instances; switchover first); also enables R15 |
| R25 | Demo Secret unencrypted in Git (not a real secret) | Operator error | 1 | 1 | 🟢 1 | Accepted | None |

## 4. What was done, what was not

**Done (hardening stage, evidence `docs/evidence/06-hardening.txt`):**
backup schedule (R06), GitHub token documented (R08), OpenBao audit log
(R11), NetworkPolicies for incoming traffic in 5 namespaces (R10), root-token
revoke script prepared (R01).

**Not done (security work paused):** Pod Security Standards (B3), narrowing
ESO's token rights (R09), narrowing `eso-read` (R20), PostgreSQL
`verify-full` (R15), egress policies (R10).

**Failure tests (2026-10-27/28, `docs/runbooks/failure-tests.md`):**

- Proven as described: R03 (restarted OpenBao pods come back sealed; F1, F3),
  R06 (the missed 12:00 UTC slot of 2026-10-27 ran at 14:51; 2026-10-28 ran on
  time), R14 (F2 failover; the data-loss window was not measured), R16 (F1: the
  stopped node's pods were not rescheduled), R21 (F4: value and all versions
  deleted).
- Gaps confirmed: R04 (F1: losing one node stopped OpenBao for 76 s, mostly
  node detection), R11 (F3: the store stays "Valid" while OpenBao is sealed;
  nothing alerts).
- Fixed: the restore path (R10): the NetworkPolicy did not let the operator
  reach a restore cluster; `allow-instance-manager` now covers every
  CloudNativePG instance.
- New: R27 (pod network after a Codespace restart), R28 (slow failover when
  the primary pod is deleted), R29 (single-replica controllers).

**Not verified:** OpenBao reloading its certificate on `SIGHUP` (R12); the
password-manager copies of the keys (R02, R19).

**Monitoring (2026-10-28, ADR 0007, `docs/evidence/08-monitoring.txt`):**

- Now detected by an alert: R03 / sealed OpenBao (OpenBaoSealed, fired in the
  M6 re-run of F3 after 2 min 22 s), R06 / late or failed backup
  (BackupFailedOrTooOld), R14 and R28 / PostgreSQL instance or primary missing
  (PostgresNotHealthy), R16 / lost node (NodeNotReady), R29 / ESO controller
  gone (ExternalSecretsControllerDown), R11 / ESO syncs failing
  (ExternalSecretNotReady, PushSecretNotReady, ClusterSecretStoreNotReady).
  Only OpenBaoSealed was proven by a test; the others by rule unit tests
  (`promtool test rules`) and the real metrics.
- New findings: in the M6 run the store did go to `InvalidProviderConfig`
  after 142 s sealed (F3 with 2 min sealed never saw it, R11); the OpenBao
  metrics listener keeps answering while sealed; ESO alerts first named the
  controller's namespace instead of the object's (fixed with `honorLabels`);
  ESO's chart default for metrics TLS silently falls back to a self-signed
  certificate (avoided, ADR 0007).
- New risks: R30 (PostgreSQL metrics plain HTTP, known gap), R31 (monitoring
  itself single and silent).
