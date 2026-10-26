# Risk assessment: OpenBao platform (current setup)

- Date: 2026-10-26
- Scope: everything deployed from this repository as of the External Secrets
  stage: kind cluster in a GitHub Codespace, Flux, SOPS/age, cert-manager,
  Traefik, SeaweedFS, CloudNativePG, OpenBao (HA on PostgreSQL), External
  Secrets Operator, and the operator scripts in `scripts/`.
- Basis: the manifests, scripts, ADRs 0001-0005 and the evidence in
  `docs/evidence/`. Points that were not verified in the running cluster are
  listed at the end.

## Method

Each risk gets a **likelihood** and an **impact** from 1 to 5, for the setup as
it runs today. **Score = likelihood x impact.**

| Value | Likelihood (in the life of the setup) | Impact |
| --- | --- | --- |
| 1 | Rare: needs several unusual events | Negligible: no effect on secrets or service |
| 2 | Unlikely: possible, no sign of it yet | Minor: short degradation, no data or secret exposed |
| 3 | Possible: can happen in normal operation | Moderate: outage of a component, recoverable by runbook |
| 4 | Likely: expected to happen sooner or later | Major: platform-wide outage, or some data lost / some secrets exposed |
| 5 | Almost certain: happens routinely | Severe: all secrets exposed, or OpenBao data lost for good |

Rating: 🔴 **High 15-25**, 🟡 **Medium 8-14**, 🟢 **Low 1-7**.

## Risk matrix

Rows = impact, columns = likelihood. Each cell shows its score band
(🔴 High 15-25, 🟡 Medium 8-14, 🟢 Low 1-7) and the risk IDs that fall into it
(register below).

| Impact \ Likelihood | 1 Rare | 2 Unlikely | 3 Possible | 4 Likely | 5 Almost certain |
| --- | --- | --- | --- | --- | --- |
| **5 Severe** | 🟢 | 🟡 R02, R07, R08, R09 | 🔴 **R01, R04, R05** | 🔴 | 🔴 |
| **4 Major** | 🟢 R15 | 🟡 R13, R18, R19 | 🟡 R12 | 🔴 | 🔴 |
| **3 Moderate** | 🟢 | 🟢 R14, R20, R21, R22 | 🟡 R10, R17 | 🟡 R11 | 🔴 **R03** |
| **2 Minor** | 🟢 | 🟢 R06, R24 | 🟢 R16, R23 | 🟡 | 🟡 |
| **1 Negligible** | 🟢 R25 | 🟢 | 🟢 | 🟢 | 🟢 |

🔴 High (15): R01, R03, R04, R05. 🟡 Medium (8-12): R02, R07, R08, R09,
R10, R11, R12, R13, R17, R18, R19. 🟢 Low (1-6): the rest.

## Risk register

| ID | Risk | Cat. | L | I | Score | Existing controls | Recommended treatment |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R01 | All 5 unseal key shares and the root token are held together (`~/openbao-init.json` and Codespaces secrets of one GitHub account); the root token is not revoked | Security | 3 | 5 | 🔴 15 | File `chmod 600` outside the repo; values never printed; Codespaces secrets limited to this repo | Revoke the root token now (runbook section 6); production: auto-unseal (KMS/HSM) with recovery keys, or key shares split across people / PGP-encrypted; protect the GitHub account (hardware 2FA) |
| R02 | Fewer than 3 key shares survive (file, download and Codespaces secrets lost) -> OpenBao data can never be decrypted; PostgreSQL backups do not help | Data loss | 2 | 5 | 🟡 10 | Three copies (file, Codespaces secrets, password manager per `docs/environment.md`) | Check the off-Codespace copy exists; test an unseal from it; production: auto-unseal + recovery keys in separate custody |
| R03 | Every pod or Codespace restart leaves OpenBao sealed until someone runs `openbao-unseal.sh`; meanwhile the store and `apps-external-secrets` are not Ready and secrets are not refreshed | Availability | 5 | 3 | 🔴 15 | `resume.sh` prints the reminder; unseal script is idempotent; existing Kubernetes Secrets stay | Production: auto-unseal; until then alert on `openbao-sealed=true` |
| R04 | All "nodes" are containers on one Codespace VM: host failure, Codespace stop or deletion takes out every replica at once; the HA design only protects against pod/container failure | Availability / data loss | 3 | 5 | 🔴 15 | Codespace idle stop is a clean stop; `resume.sh` restores; environment documented as a demo | Production: real nodes in at least 3 failure zones; treat the Codespace as disposable and never as the only copy of anything |
| R05 | Backups live in the same failure domain: SeaweedFS is 1 pod on a local-path volume inside the same cluster; losing the cluster or that node loses all base backups and WAL | Data loss | 3 | 5 | 🔴 15 | Daily base backup, continuous WAL archiving, PITR tested (ADR 0003) | Off-cluster object storage (another region/account), with object lock/versioning; regular restore test |
| R06 | Daily base backup does not run at its slot while the Codespace is stopped. Corrected after reading the CloudNativePG 1.30 source (`scheduledbackup_controller.go`): a missed slot is run once as soon as the operator runs again, so the backup is late, not lost; nothing writes to the database while the cluster is stopped. Remaining risk: no alert if scheduling breaks for another reason. Originally rated L4 I3 (12) on the wrong assumption that missed backups never run | Data loss | 2 | 2 | 🟢 4 | Catch-up of a missed slot (source code); WAL archiving whenever the cluster runs; schedule moved to 12:00 UTC (hardening A1, `docs/evidence/06-hardening.txt`) | Production: alert on the age of the last successful backup |
| R07 | Flux `prune: true` on every layer: removing or renaming `apps/database/cluster.yaml` or a layer path deletes the PostgreSQL Cluster (and its volumes) or OpenBao objects. **Status: accepted** (hardening A2, owner decision 2026-10-26: no prune protection; the annotation was verified in the kustomize-controller v1.9.6 docs but not applied, so the demo can still be torn down entirely from Git) | Data loss / GitOps | 2 | 5 | 🟡 10 | Small reviewed commits; WAL backups allow a restore into a new cluster | Annotate stateful objects with `kustomize.toolkit.fluxcd.io/prune: disabled` (Cluster, PVC-owning objects, Namespaces); branch protection with review |
| R08 | Write access to the Git repository equals cluster admin (Flux applies whatever is on `main`); no branch protection or signed-commit verification. `docs/environment.md` says `FLUX_GITHUB_TOKEN` is a fine-grained token limited to this repo, but setup notes show the `gh` CLI token (scopes `repo`, `codespace:secrets`) being stored as that secret | Security / GitOps | 2 | 5 | 🟡 10 | Private repo, single maintainer | Use a fine-grained, repo-scoped, expiring token (and confirm which token is stored); branch protection + required review on `main`; Flux commit signature verification (`spec.verify` on the GitRepository) |
| R09 | ESO's controller ClusterRole can read/write every Secret and **create tokens for any service account** (`rbac.serviceAccountTokenCreate: true`, no `resourceNames`); a compromised ESO pod can impersonate any service account and read e.g. `cert-manager/demo-root-ca` (CA private key) or `openbao/openbao-server-tls` | Security | 2 | 5 | 🟡 10 | ESO runs from a pinned official chart; no other workloads in the cluster | Set `rbac.serviceAccountTokenCreate: false` and grant token creation only for `external-secrets` (Role with `resourceNames`); scope ESO's Secret access to the namespaces it serves; keep the ESO image patched |
| R10 | No NetworkPolicies: any pod in any namespace can reach the OpenBao API, PostgreSQL and the SeaweedFS S3 endpoint | Security | 3 | 3 | 🟡 9 | All three need credentials (OpenBao token, DB password, S3 keys); OpenBao now on TLS | NetworkPolicies: OpenBao only from Traefik, ESO and its own pods; PostgreSQL only from OpenBao and CNPG; S3 only from `databases` (they only work if the CNI enforces them; recent kind releases are said to add this to kindnet, not verified for this cluster) |
| R11 | No OpenBao audit device and no monitoring/alerting: a sealed OpenBao, failed backups or WAL archiving, an expiring certificate or a misused token go unnoticed and leave no audit trail | Detection | 4 | 3 | 🟡 12 | Manual check scripts; runbooks | Enable a file audit device on a volume (or socket to a log system); Prometheus + alerts on seal status, `cnpg` backup/archiving metrics, cert-manager expiry, ESO sync errors |
| R12 | OpenBao loads its listener certificate only at start; after cert-manager's renewal (day 75 of 90) the pods keep the old certificate until restarted by hand; if forgotten, at day 90 ESO and Traefik fail TLS to OpenBao | Availability | 3 | 4 | 🟡 12 | Documented in ADR 0005 and both runbooks | Automate: a reloader that restarts pods one by one on Secret change plus an unseal step, or send `SIGHUP` (check that OpenBao reloads listener certificates on SIGHUP); alert on certificate age |
| R13 | Self-signed demo root CA: private key stored as a Kubernetes Secret, 1-year lifetime, renewed in place by cert-manager; a leak lets anyone issue certificates trusted by ESO and Traefik; renewal changes the CA that external clients must trust | Security | 2 | 4 | 🟡 8 | Key only in `cert-manager` namespace; consumers read `ca.crt` at runtime | Production: an internal PKI or OpenBao PKI with an offline root; limit who can read Secrets in `cert-manager` |
| R14 | Asynchronous PostgreSQL replication and `archive_timeout: 5min`: a failover can lose the last committed transactions; a total loss can lose up to about 5 minutes of writes (e.g. a secret just written to OpenBao) | Data loss | 2 | 3 | 🟢 6 | Measured failover 7 s; WAL archiving | Synchronous replication (`minSyncReplicas: 1`) if zero data loss is required; shorter `archive_timeout` |
| R15 | OpenBao connects to PostgreSQL with `sslmode=require`: encrypted but the server certificate is not verified, so an in-cluster attacker who can redirect traffic could intercept the connection | Security | 1 | 4 | 🟢 4 | Traffic stays inside the cluster; password auth | `sslmode=verify-full` with the CNPG CA mounted into OpenBao |
| R16 | Required anti-affinity with exactly 3 workers and no spare node: losing one worker leaves one OpenBao pod and one PostgreSQL instance `Pending` until it returns; draining a node for maintenance has nowhere to move them | Availability | 3 | 2 | 🟢 6 | Remaining 2 replicas keep serving; PDB `maxUnavailable: 1` for OpenBao | Production: N+1 nodes per zone; topology spread across zones |
| R17 | OpenBao's internal configuration (mounts, auth methods, roles; policies are in files) is applied by scripts with the root token, not reconciled from Git; drift is not detected and a rebuild depends on running the scripts in order | Operations | 3 | 3 | 🟡 9 | Idempotent scripts; policy text in `openbao/policies/` | OpenTofu/Terraform provider in a pipeline (or a config operator) with a scoped admin token instead of root |
| R18 | Supply chain: charts and images pinned by version tag, not by digest; no signature verification; public registries | Security | 2 | 4 | 🟡 8 | Exact versions (ADR 0001); chart digests checked once against repo indexes | Pin image digests; verify signatures (cosign) with an admission policy; renovate-style update PRs |
| R19 | One age key decrypts every SOPS secret in Git, including the full history; a leak exposes the DB password and S3 keys (rotation does not remove old ciphertext from history); loss means secrets cannot be edited | Security | 2 | 4 | 🟡 8 | Private key only in Codespaces secret, password manager and `flux-system/sops-age` | A second recipient (break-glass key) for recovery; production: KMS-backed SOPS keys; rotate the secrets after any suspected leak |
| R20 | `eso-read` allows reading all of `secret/`, and the single ClusterSecretStore serves every namespace listed in its `conditions`; adding a namespace there gives it every secret | Security | 2 | 3 | 🟢 6 | `conditions` limited to `eso-demo` | Per-team stores, roles and policies limited to their paths |
| R21 | PushSecret `deletionPolicy: Delete`: deleting the PushSecret from Git permanently removes the value and all versions in OpenBao | Data loss | 2 | 3 | 🟢 6 | Only values marked `managed-by: external-secrets` below `secret/pushed/`; source Secret remains | Keep `Delete` only where Kubernetes is the source of truth; review deletions in PRs |
| R22 | Tight resource limits on a 16 GB host (OpenBao 256Mi, PostgreSQL 512Mi): memory pressure or OOM kills under load, each kill seals that OpenBao pod | Availability | 2 | 3 | 🟢 6 | Observed usage within limits; no restarts seen | Load test; raise limits; monitor restarts |
| R23 | OpenBao uses `updateStrategy: OnDelete`: a change in Git updates the StatefulSet but not the running pods, so Git and runtime differ until someone restarts them | Operations | 3 | 2 | 🟢 6 | `openbao-tls-rollout.sh` restarts pods on an old revision | Alert when `currentRevision != updateRevision`; run the rollout script after every OpenBao change |
| R24 | One Traefik replica on the control-plane node (hostPort): its loss stops HTTPS access to the UI/API from outside (in-cluster ESO traffic is not affected) | Availability | 2 | 2 | 🟢 4 | Recreated by Kubernetes | Production: load balancer + 2 or more replicas |
| R25 | Demo source Secret `eso-demo/push-demo` is stored unencrypted in Git | Security | 1 | 1 | 🟢 1 | Value is a non-secret demo string; file header says so | None needed; never copy the pattern for real values |

## The four High risks in detail

**R01: key material concentrated in one place.** Anyone who gets into the
GitHub account (or a Codespace of this repository) gets the environment
variables `OPENBAO_UNSEAL_KEYS` and `OPENBAO_ROOT_TOKEN`, and with them every
secret in OpenBao, without any audit trail (R11). Splitting the key into five
shares adds nothing while one person holds all five. Cheapest fix today:
revoke the root token. Structural fix: auto-unseal, so no person holds the
unseal key at all.

**R03: manual unseal versus a stop-start environment.** The Codespace stops
on idle, so OpenBao is sealed at the start of every work session and after any
pod restart. The design fails safe (secrets stay locked, existing Kubernetes
Secrets stay), but the platform is not self-healing: nothing secret-related
recovers without a person.

**R04 and R05: one host and one backup location.** The three-replica design
of OpenBao and PostgreSQL is real but runs on one VM, and the backups live on
that same VM. Deleting the Codespace (as planned after the review) removes the
cluster, the data and the backups together. This is accepted for the demo; it
is the first thing production must change.

## Accepted for the demo vs. required for production

- **Accepted for the demo** (documented in ADRs): R03, R04, R05, R14, R16, R22,
  R24, R25. They follow from running on one Codespace without cloud services.
- **Should be fixed even in the demo** (cheap): R01 (revoke root token),
  R07 (prune protection on the Cluster), R08
  (confirm the token type, branch protection), R09 (narrow ESO token
  creation).
- **Required before production**: everything above plus R10, R11, R12, R13,
  R15, R17, R18, R19, R20.

## Assumptions and points not verified

- Whether `flux bootstrap github` created a read-only or read-write deploy key
  was not checked in GitHub (default is read-only, as far as known).
- CloudNativePG catches up a missed `ScheduledBackup` slot once when the
  operator runs again: read in the 1.30 source, not yet observed in this cluster (R06).
- Which token is stored in `FLUX_GITHUB_TOKEN` was not checked (R08): the
  setup notes and `docs/environment.md` disagree.
- Whether OpenBao 2.7.1 reloads listener certificates on `SIGHUP` was not
  tested (R12).
- Whether this cluster's kindnet enforces NetworkPolicies was not checked
  (R10): test with a deny-all policy before relying on it.
- Likelihood values are judgements for this setup, not measured rates.
