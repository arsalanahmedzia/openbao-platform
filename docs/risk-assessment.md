# Risk assessment: OpenBao platform

| | |
| --- | --- |
| **Last updated** | 2026-10-26 (during the hardening stage, after item B2) |
| **Scope** | Everything deployed from this repository: kind cluster in a GitHub Codespace, Flux, SOPS/age, cert-manager, Traefik, SeaweedFS, CloudNativePG, OpenBao (HA on PostgreSQL), External Secrets Operator, and the scripts in `scripts/` |
| **Based on** | Manifests, scripts, ADRs 0001-0005, evidence in `docs/evidence/` (hardening: `06-hardening.txt`) |

**How to read this document:** the [summary](#1-summary) and the
[matrix](#2-risk-matrix) give the picture in one minute. The
[overview](#3-all-risks-at-a-glance) lists every risk in one line. The
[details](#4-risk-details) explain each risk: what can happen, what is in
place, what to do next.

---

## 1. Summary

**26 risks:** 🔴 4 High · 🟡 11 Medium · 🟢 11 Low

| Status | Count | Meaning |
| --- | --- | --- |
| **Open** | 11 | Not treated yet; a fix is described |
| **Partly mitigated** | 3 | Something was built and tested; a gap remains |
| **Mitigated** | 1 | Treated and tested; small rest risk |
| **Accepted** | 11 | Known and deliberately left as is (demo environment or owner decision) |

**The four High risks** all come from running a demo on one machine with
manual key handling:

| ID | Risk | Score | Status |
| --- | --- | --- | --- |
| R01 | All unseal key shares and the root token are held in one place | 🔴 15 | Open (revoke script ready) |
| R03 | Every restart leaves OpenBao sealed until a person unseals it | 🔴 15 | Accepted (demo) |
| R04 | All cluster nodes run on one Codespace VM | 🔴 15 | Accepted (demo) |
| R05 | Backups are stored inside the same cluster | 🔴 15 | Accepted (demo) |

**Changed by the hardening stage so far:** R06 corrected and mitigated,
R07 accepted, R08 checked (still open), R10 and R11 partly mitigated, R23
partly mitigated, R26 added.

---

## 2. Risk matrix

Each risk gets a **likelihood** (L) and an **impact** (I) from 1 to 5;
**score = L x I**. Rows are impact, columns are likelihood; each cell is
coloured by its score: 🔴 High 15-25 · 🟡 Medium 8-14 · 🟢 Low 1-7.
The scales are defined in the [appendix](#7-appendix-scoring-scales).

| Impact \ Likelihood | 1 Rare | 2 Unlikely | 3 Possible | 4 Likely | 5 Almost certain |
| --- | --- | --- | --- | --- | --- |
| **5 Severe** | 🟢 | 🟡 R02, R07, R08, R09 | 🔴 **R01, R04, R05** | 🔴 | 🔴 |
| **4 Major** | 🟢 R15 | 🟡 R13, R18, R19, R26 | 🟡 R12 | 🔴 | 🔴 |
| **3 Moderate** | 🟢 | 🟢 R10, R14, R20, R21, R22 | 🟡 R17 | 🟡 R11 | 🔴 **R03** |
| **2 Minor** | 🟢 | 🟢 R06, R24 | 🟢 R16, R23 | 🟡 | 🟡 |
| **1 Negligible** | 🟢 R25 | 🟢 | 🟢 | 🟢 | 🟢 |

---

## 3. All risks at a glance

Sorted by score.

| ID | Risk | Area | L | I | Score | Status |
| --- | --- | --- | --- | --- | --- | --- |
| R01 | Unseal keys and root token held in one place | Security | 3 | 5 | 🔴 15 | Open |
| R03 | OpenBao sealed after every restart | Availability | 5 | 3 | 🔴 15 | Accepted |
| R04 | All nodes on one Codespace VM | Availability | 3 | 5 | 🔴 15 | Accepted |
| R05 | Backups inside the same cluster | Data loss | 3 | 5 | 🔴 15 | Accepted |
| R11 | No monitoring or alerting | Detection | 4 | 3 | 🟡 12 | Partly mitigated |
| R12 | Listener certificate renewal needs manual restarts | Availability | 3 | 4 | 🟡 12 | Open |
| R02 | Losing the key shares loses all OpenBao data | Data loss | 2 | 5 | 🟡 10 | Open |
| R07 | Flux prune can delete the database | Data loss | 2 | 5 | 🟡 10 | Accepted |
| R08 | Git write access equals cluster admin; broad GitHub token | Security | 2 | 5 | 🟡 10 | Open |
| R09 | ESO may create tokens for any service account | Security | 2 | 5 | 🟡 10 | Open |
| R17 | OpenBao configuration not reconciled from Git | Operations | 3 | 3 | 🟡 9 | Open |
| R13 | Demo root CA key stored in the cluster | Security | 2 | 4 | 🟡 8 | Accepted |
| R18 | Images not pinned by digest or signature | Security | 2 | 4 | 🟡 8 | Open |
| R19 | One age key decrypts every SOPS secret | Security | 2 | 4 | 🟡 8 | Open |
| R26 | Kubernetes Secrets not encrypted at rest | Security | 2 | 4 | 🟡 8 | Open |
| R10 | Network access between namespaces | Security | 2 | 3 | 🟢 6 | Partly mitigated |
| R14 | Asynchronous replication can lose recent writes | Data loss | 2 | 3 | 🟢 6 | Accepted |
| R16 | No spare node for rescheduling | Availability | 3 | 2 | 🟢 6 | Accepted |
| R20 | ESO may read all of `secret/` | Security | 2 | 3 | 🟢 6 | Open |
| R21 | Deleting the PushSecret deletes the value in OpenBao | Data loss | 2 | 3 | 🟢 6 | Accepted |
| R22 | Tight memory limits | Availability | 2 | 3 | 🟢 6 | Accepted |
| R23 | Running OpenBao pods can differ from Git | Operations | 3 | 2 | 🟢 6 | Partly mitigated |
| R06 | Scheduled backup late while the Codespace is stopped | Data loss | 2 | 2 | 🟢 4 | Mitigated |
| R15 | OpenBao does not verify PostgreSQL's certificate | Security | 1 | 4 | 🟢 4 | Open |
| R24 | One Traefik replica | Availability | 2 | 2 | 🟢 4 | Accepted |
| R25 | Demo source Secret unencrypted in Git | Security | 1 | 1 | 🟢 1 | Accepted |

---

## 4. Risk details

### 🔴 High

#### R01 · Unseal keys and root token held in one place
**Score 🔴 15** (L3 × I5) · **Status: Open** (revoke script ready)

- **What can happen:** all 5 key shares and the root token sit in
  `~/openbao-init.json` and in the Codespaces secrets of one GitHub account.
  Anyone who gets into that account or a Codespace of this repository gets
  every secret in OpenBao. Five shares add nothing while one person holds all of them.
- **In place today:** file `chmod 600` outside the repo; values never printed;
  Codespaces secrets limited to this repository.
- **Next step:** revoke the root token with `scripts/openbao-revoke-root.sh`
  (hardening A5; prepared, not run yet). Production: auto-unseal (KMS/HSM)
  with recovery keys in separate custody; hardware 2FA on the account.

#### R03 · OpenBao sealed after every restart
**Score 🔴 15** (L5 × I3) · **Status: Accepted** (demo)

- **What can happen:** the Codespace stops on idle, so every work session and
  every pod restart starts with sealed OpenBao pods. Until someone runs
  `scripts/openbao-unseal.sh`, the store and the layer `apps-external-secrets`
  are not Ready and secrets are not refreshed.
- **In place today:** fails safe (secrets stay locked, existing Kubernetes
  Secrets stay); `resume.sh` prints the reminder; the unseal script is idempotent.
- **Next step:** production: auto-unseal; until then, alert on `openbao-sealed=true`.

#### R04 · All nodes on one Codespace VM
**Score 🔴 15** (L3 × I5) · **Status: Accepted** (demo)

- **What can happen:** the 4 kind "nodes" are containers on one VM. A host
  failure, stop or deletion of the Codespace takes out every replica at once.
  The HA design protects only against pod or container failure.
- **In place today:** a Codespace stop is a clean stop; `resume.sh` restores;
  documented as a demo environment.
- **Next step:** production: real nodes in at least 3 failure zones.

#### R05 · Backups inside the same cluster
**Score 🔴 15** (L3 × I5) · **Status: Accepted** (demo)

- **What can happen:** SeaweedFS is 1 pod on a local-path volume in the same
  cluster. Losing the cluster or that node loses all base backups and WAL;
  deleting the Codespace removes data and backups together.
- **In place today:** daily base backup, continuous WAL archiving, PITR tested
  (ADR 0003); S3 reachable only from `databases` (R10).
- **Next step:** production: off-cluster object storage in another account or
  region, with versioning or object lock; regular restore tests.

### 🟡 Medium

#### R11 · No monitoring or alerting
**Score 🟡 12** (L4 × I3) · **Status: Partly mitigated** (hardening A4)

- **What can happen:** a sealed OpenBao, failed backups or WAL archiving, an
  expiring certificate or a misused token go unnoticed.
- **In place today:** OpenBao audit device to stdout (declared in the server
  config): every request is logged with values and tokens as HMAC hashes
  (evidence A4). The trail is short-lived, because kubelet rotates pod logs.
- **Next step:** ship pod logs to a log system; Prometheus with alerts on seal
  status, backup and archiving age, certificate expiry, ESO sync errors.

#### R12 · Listener certificate renewal needs manual restarts
**Score 🟡 12** (L3 × I4) · **Status: Open**

- **What can happen:** OpenBao loads its listener certificate only at start.
  cert-manager renews it on day 75 of 90; if the pods are not restarted, ESO
  and Traefik fail TLS to OpenBao on day 90.
- **In place today:** documented in ADR 0005 and both runbooks.
- **Next step:** automate a pod-by-pod restart with unseal on Secret change, or
  `SIGHUP` (not tested whether OpenBao reloads the certificate on SIGHUP);
  alert on certificate age.

#### R02 · Losing the key shares loses all OpenBao data
**Score 🟡 10** (L2 × I5) · **Status: Open**

- **What can happen:** if fewer than 3 shares survive (file, download,
  Codespaces secrets all lost), the data can never be decrypted. PostgreSQL
  backups do not help: they hold the same encrypted data.
- **In place today:** three copies (file, Codespaces secrets, password manager
  per `docs/environment.md`; the password manager copy is not checked here).
- **Next step:** check the off-Codespace copy exists and test an unseal from it.
  Production: auto-unseal with recovery keys in separate custody.

#### R07 · Flux prune can delete the database
**Score 🟡 10** (L2 × I5) · **Status: Accepted** (owner decision, hardening A2)

- **What can happen:** every Flux layer has `prune: true`. Removing or renaming
  `apps/database/cluster.yaml` or a layer path deletes the PostgreSQL Cluster
  and its volumes.
- **In place today:** small reviewed commits; WAL backups allow a restore into
  a new cluster. The protection annotation `kustomize.toolkit.fluxcd.io/prune:
  disabled` was verified in the kustomize-controller v1.9.6 docs but not
  applied, so the demo can still be torn down entirely from Git.
- **Next step:** production: annotate the Cluster, PVC-owning objects and their
  Namespaces; required reviews on `main`.

#### R08 · Git write access equals cluster admin; broad GitHub token
**Score 🟡 10** (L2 × I5) · **Status: Open** (owner checklist, hardening A3)

- **What can happen:** Flux applies whatever is on `main`; there is no branch
  protection and no signed-commit check. `FLUX_GITHUB_TOKEN` is the `gh` CLI
  OAuth token (scopes `repo`, `workflow`, `codespace:secrets`, `gist`,
  `read:org`, no expiry): it can write to every repository of the account and
  to the Codespaces secrets that hold the unseal keys.
- **In place today:** single maintainer; Flux reads Git through a **read-only**
  deploy key (checked), so a compromised cluster cannot push to Git;
  `docs/environment.md` states the real token.
- **Next step:** owner checklist in `docs/environment.md` (2FA with passkey,
  ruleset on `main` against force push and deletion, fine-grained repo-only
  token with expiry, revoke tokens and keys at the end). Production: required
  reviews and Flux commit signature verification.

#### R09 · ESO may create tokens for any service account
**Score 🟡 10** (L2 × I5) · **Status: Open** (planned: hardening B4)

- **What can happen:** ESO's controller ClusterRole can read and write every
  Secret and create tokens for any service account (`rbac.serviceAccountTokenCreate:
  true`, no `resourceNames`). A compromised ESO pod could act as any service
  account and read e.g. the demo root CA key.
- **In place today:** pinned official chart; no other workloads in the cluster.
- **Next step:** disable cluster-wide token creation and allow it only for
  `external-secrets` (Role with `resourceNames`); production: publish only the
  CA (trust-manager) and narrow ESO's Secret access.

#### R17 · OpenBao configuration not reconciled from Git
**Score 🟡 9** (L3 × I3) · **Status: Open**

- **What can happen:** mounts, auth methods and roles are applied by scripts
  with the root token. Drift is not detected, and a rebuild depends on running
  the scripts in order.
- **In place today:** idempotent scripts; policy text in `openbao/policies/`;
  the audit device is declared in the server config in Git.
- **Next step:** production: OpenTofu/Terraform provider in a pipeline (or a
  config operator) with a scoped admin token instead of root.

#### R13 · Demo root CA key stored in the cluster
**Score 🟡 8** (L2 × I4) · **Status: Accepted** (demo)

- **What can happen:** the self-signed root CA key is a Kubernetes Secret in
  `cert-manager`, valid 1 year, renewed in place. A leak lets anyone issue
  certificates that ESO and Traefik trust; a renewal changes the CA external
  clients must trust.
- **In place today:** key only in namespace `cert-manager`; consumers read
  `ca.crt` at runtime.
- **Next step:** production: internal PKI or OpenBao PKI with an offline root;
  limit who can read Secrets in `cert-manager` (see also R09).

#### R18 · Images not pinned by digest or signature
**Score 🟡 8** (L2 × I4) · **Status: Open**

- **What can happen:** a re-pushed tag or a compromised public registry could
  change what runs, without any change in Git.
- **In place today:** exact versions (ADR 0001); chart digests checked once
  against the repository indexes.
- **Next step:** production: pin image digests, verify signatures (cosign) with
  an admission policy, automated update pull requests.

#### R19 · One age key decrypts every SOPS secret
**Score 🟡 8** (L2 × I4) · **Status: Open**

- **What can happen:** a leak of the age key exposes the DB password and S3
  keys, including every old version in Git history; losing the key means the
  secrets in Git cannot be edited (they can be regenerated).
- **In place today:** private key only in a Codespaces secret, a password
  manager and the cluster Secret `flux-system/sops-age`.
- **Next step:** a second recipient as break-glass key; production: KMS-backed
  SOPS keys; rotate the secrets after any suspected leak.

#### R26 · Kubernetes Secrets not encrypted at rest
**Score 🟡 8** (L2 × I4) · **Status: Open** (production gap)

- **What can happen:** kind stores Secrets in etcd only base64-encoded. Anyone
  with access to etcd data or a node's disk reads every Secret: the age key
  (`sops-age`), the DB password, the S3 keys, the OpenBao TLS key, the root CA key.
- **In place today:** etcd lives inside the control-plane container of a
  private Codespace.
- **Next step:** production: encryption at rest with a KMS provider; needs a
  cluster rebuild with an `EncryptionConfiguration` for the API server.

### 🟢 Low

#### R10 · Network access between namespaces
**Score 🟢 6** (L2 × I3, was L3 × I3 = 9) · **Status: Partly mitigated** (hardening B1, B2)

- **What can happen:** a compromised pod reaches services it should not talk to.
- **In place today:** kindnet enforces NetworkPolicies (tested, B1). `storage`,
  `databases`, `openbao`, `external-secrets` and `eso-demo` deny all incoming
  traffic and allow only tested paths (B2). All three back ends still require
  credentials; OpenBao uses TLS.
- **Remaining:** no policies in `traefik`, `cert-manager`, `cnpg-system`,
  `flux-system`, `kube-system`; no egress policies (skipped, owner decision);
  the node range `172.16.0.0/12` may reach the PostgreSQL instance manager
  (8000) and the ESO webhook (10250), which the API server needs.

#### R14 · Asynchronous replication can lose recent writes
**Score 🟢 6** (L2 × I3) · **Status: Accepted** (demo)

- **What can happen:** a failover can lose the last committed transactions; a
  total loss up to about 5 minutes of writes (`archive_timeout: 5min`), e.g. a
  secret just written to OpenBao.
- **In place today:** measured failover 7 s; continuous WAL archiving.
- **Next step:** synchronous replication (`minSyncReplicas: 1`) if zero data
  loss is required; shorter `archive_timeout`.

#### R16 · No spare node for rescheduling
**Score 🟢 6** (L3 × I2) · **Status: Accepted** (demo)

- **What can happen:** required anti-affinity with exactly 3 workers: losing a
  worker leaves one OpenBao pod and one PostgreSQL instance `Pending` until it
  returns; a node cannot be drained for maintenance.
- **In place today:** the other 2 replicas keep serving; PDB `maxUnavailable: 1`.
- **Next step:** production: N+1 nodes per zone, topology spread across zones.

#### R20 · ESO may read all of `secret/`
**Score 🟢 6** (L2 × I3) · **Status: Open** (planned: hardening B5)

- **What can happen:** `eso-read` covers all of `secret/`, and the single
  ClusterSecretStore serves every namespace listed in its `conditions`; adding
  a namespace there gives it every secret.
- **In place today:** `conditions` limited to `eso-demo`.
- **Next step:** limit `eso-read` to the paths ESO needs; production:
  per-team stores, roles and policies.

#### R21 · Deleting the PushSecret deletes the value in OpenBao
**Score 🟢 6** (L2 × I3) · **Status: Accepted** (design, ADR 0005)

- **What can happen:** `deletionPolicy: Delete` removes the value and all its
  versions in OpenBao when the PushSecret leaves Git.
- **In place today:** ESO only deletes values marked `managed-by:
  external-secrets` below `secret/pushed/`; the source Secret remains.
- **Next step:** use `Delete` only where Kubernetes is the source of truth;
  review deletions in pull requests.

#### R22 · Tight memory limits
**Score 🟢 6** (L2 × I3) · **Status: Accepted** (demo)

- **What can happen:** memory pressure or OOM kills on the 16 GB host
  (OpenBao 256Mi, PostgreSQL 512Mi); each kill seals that OpenBao pod.
- **In place today:** observed usage within limits; no restarts from memory.
- **Next step:** load test; raise limits; monitor restarts.

#### R23 · Running OpenBao pods can differ from Git
**Score 🟢 6** (L3 × I2) · **Status: Partly mitigated** (hardening A4)

- **What can happen:** OpenBao uses `updateStrategy: OnDelete`, so a change in
  Git updates the StatefulSet but not the running pods.
- **In place today:** `configAnnotation: true` makes every config change a new
  StatefulSet revision, and `scripts/openbao-tls-rollout.sh` restarts exactly
  the outdated pods and unseals them.
- **Next step:** alert when `currentRevision != updateRevision`.

#### R06 · Scheduled backup late while the Codespace is stopped
**Score 🟢 4** (L2 × I2, was L4 × I3 = 12) · **Status: Mitigated** (hardening A1)

- **What can happen:** the daily base backup slot passes while the cluster is
  stopped.
- **In place today:** CloudNativePG runs a missed slot once as soon as the
  operator runs again (1.30 source, `scheduledbackup_controller.go`), so the
  backup is late, not lost, and nothing writes to the database while it is
  stopped. The schedule moved to 12:00 UTC, when the Codespace usually runs.
  The original rating assumed missed backups never run; that was wrong.
- **Next step:** production: alert on the age of the last successful backup.

#### R15 · OpenBao does not verify PostgreSQL's certificate
**Score 🟢 4** (L1 × I4) · **Status: Open** (optional: hardening B6)

- **What can happen:** `sslmode=require` encrypts but does not check the
  server certificate; an in-cluster attacker able to redirect traffic could
  intercept the connection.
- **In place today:** traffic stays inside the cluster; password
  authentication; PostgreSQL reachable only from OpenBao pods (R10).
- **Next step:** `sslmode=verify-full` with the CloudNativePG CA mounted into OpenBao.

#### R24 · One Traefik replica
**Score 🟢 4** (L2 × I2) · **Status: Accepted** (demo)

- **What can happen:** losing the Traefik pod stops HTTPS access from outside
  (UI/API); in-cluster ESO traffic is not affected.
- **In place today:** Kubernetes recreates the pod.
- **Next step:** production: a load balancer and 2 or more replicas.

#### R25 · Demo source Secret unencrypted in Git
**Score 🟢 1** (L1 × I1) · **Status: Accepted**

- **What can happen:** nothing secret: `eso-demo/push-demo` holds the demo
  string `pushed-from-kubernetes`; the risk is copying the pattern for real values.
- **In place today:** the file header says it is not a secret.
- **Next step:** none; real values only in `*.sops.yaml`.

---

## 5. Production gaps (not built in this demo)

| Gap | Risks | One-line production fix |
| --- | --- | --- |
| Auto-unseal | R01, R02, R03 | KMS or HSM seal, recovery keys held by different people |
| Off-cluster backups | R05 | Object storage in another account/region with versioning or object lock |
| Secrets encrypted at rest | R26 | API server `EncryptionConfiguration` with a KMS provider (cluster rebuild) |
| Image digests and signatures | R18 | Digest pins plus cosign verification in an admission policy |
| Publish only the CA | R09, R13 | trust-manager distributes `ca.crt` as a ConfigMap; ESO no longer reads Secrets holding keys |
| Monitoring and alerting | R11, R12, R23 | Prometheus and alerts on seal status, backup age, certificate expiry, ESO errors, revision drift |
| OpenBao configuration as code | R17 | OpenTofu/Terraform provider in a pipeline with a scoped admin token |
| Multi-zone nodes | R04, R16 | At least 3 failure zones, N+1 nodes, topology spread |

---

## 6. Decisions

- **Accepted for the demo** (follow from one Codespace without cloud
  services): R03, R04, R05, R13, R14, R16, R22, R24, R25.
- **Accepted by owner decision:** R07 (no prune protection), R21 (PushSecret
  deletes on removal, ADR 0005), egress policies skipped (part of R10).
- **Cheap fixes still to do in the demo:** R01 (revoke the root token), R08
  (owner checklist), R09 (hardening B4), R20 (hardening B5).
- **Required before production:** everything above, plus R02, R10 (rest),
  R11, R12, R15, R17, R18, R19, R26.

---

## 7. Appendix: scoring scales

| Value | Likelihood (in the life of the setup) | Impact |
| --- | --- | --- |
| 1 | Rare: needs several unusual events | Negligible: no effect on secrets or service |
| 2 | Unlikely: possible, no sign of it yet | Minor: short degradation, no data or secret exposed |
| 3 | Possible: can happen in normal operation | Moderate: outage of a component, recoverable by runbook |
| 4 | Likely: expected to happen sooner or later | Major: platform-wide outage, or some data lost / some secrets exposed |
| 5 | Almost certain: happens routinely | Severe: all secrets exposed, or OpenBao data lost for good |

Likelihood values are judgements for this setup, not measured rates.

## 8. Appendix: checked and not verified

**Checked**
- `FLUX_GITHUB_TOKEN` is the `gh` OAuth token; the Flux deploy key is
  read-only (`scripts/github-access-check.sh`, R08).
- kindnet (kind v0.33.0) enforces NetworkPolicies, deny and allow, across
  nodes (`scripts/netpol-enforcement-test.sh`, R10).
- CloudNativePG runs a missed backup slot once when the operator runs again:
  read in the 1.30 source (R06).

**Not verified**
- The catch-up of a missed backup slot has not been observed in this cluster yet (R06).
- Whether OpenBao 2.7.1 reloads its listener certificate on `SIGHUP` (R12).
- The password-manager copies of the age key and the unseal keys (R02, R19).
- That a standby OpenBao forwards a login over 8201 rather than redirecting:
  inferred from the successful login on a standby (R10, evidence B2c).
