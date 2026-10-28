# OpenBao Platform

Production-oriented Kubernetes platform with OpenBao as the secrets management system, a highly available PostgreSQL backend, External Secrets Operator for bidirectional secret synchronization, and Flux for GitOps.

> Status: complete, failure-tested in a Codespace (kind)

## Overview

Flux applies this Git repository to the cluster in layers, each waiting for
the one before: `flux-system` → `infra-controllers` → `infra-configs` →
`infra-storage` → `apps-database` → `apps-openbao` → `apps-external-secrets`.
`apps-monitoring` (Prometheus, Alertmanager, alert rules) only waits for
`infra-controllers` and `infra-configs`. OpenBao runs as 3 pods in HA mode (one active, two standby) and stores its
data in PostgreSQL. PostgreSQL is run by CloudNativePG with 3 instances and
backs up to S3 on SeaweedFS. The External Secrets Operator syncs between
OpenBao and Kubernetes Secrets in both directions (pull and push). Traefik is
the HTTPS entry point. Prometheus scrapes OpenBao, PostgreSQL and the ESO
controller and raises alerts (sealed OpenBao, failed syncs, unhealthy
PostgreSQL, old backups, lost nodes).

### How it runs

```mermaid
flowchart TB
  user([Person with a browser])
  traefik[Traefik<br/>HTTPS entry point]
  bao[OpenBao x3<br/>keeps the secrets<br/>1 active, 2 standby]
  pg[(PostgreSQL x3<br/>OpenBao saves its data here)]
  s3[(SeaweedFS S3<br/>backup storage)]
  eso[External Secrets Operator<br/>copies secrets between<br/>OpenBao and Kubernetes]
  cm[cert-manager<br/>makes the TLS certificates]
  prom[Prometheus + Alertmanager<br/>measures and raises alerts]
  subgraph api[Kubernetes API]
    login[Login check<br/>tokens of service accounts]
    ksec[Kubernetes Secrets<br/>what apps read]
  end

  user -->|"opens the HTTPS page"| traefik
  traefik -->|"sends the request to the active pod"| bao
  eso -->|"gets a short login token"| login
  eso -->|"logs in and reads secrets"| bao
  eso -->|"logs in and writes secrets"| bao
  bao -->|"asks: is this login real?"| login
  bao -->|"saves all its data"| pg
  pg -->|"sends daily backups and WAL logs"| s3
  eso -->|"reads and writes Secrets"| ksec
  cm -->|"stores the certificates as Secrets"| ksec
  prom -.->|"measures"| bao
  prom -.->|"measures"| pg
  prom -.->|"measures"| eso
  classDef store fill:#e8f1ff,stroke:#4a6fa5
  classDef main fill:#fff4d6,stroke:#b8860b
  class pg,s3 store
  class bao,eso main
```

How to read it: an arrow points from the one who starts the call to the one who is asked. Dotted arrows are monitoring.
Not drawn, to keep it readable: unsealing OpenBao, the NetworkPolicies, SOPS + age for secrets in Git, and the daily backup schedule.
They are described in the sections below. Everything runs inside one kind cluster.
Also not drawn: pods do not call the Kubernetes API for their certificates; the kubelet (the Kubernetes agent on each node)
puts Secrets into the pods as files. The backups are sent by the Barman Cloud plugin, which runs inside each PostgreSQL pod.

Details (build order, repo map, secrets in Git, certificates, network rules, versions, design decisions): [`docs/architecture.md`](docs/architecture.md).

## Quick start

Demo environment: a GitHub Codespace (4 cores, 16 GB) running a 4-node kind cluster,
see [`docs/environment.md`](docs/environment.md).

```bash
# in a Codespace created from this repo (tools install automatically);
# secrets SOPS_AGE_KEY, FLUX_GITHUB_TOKEN, GITHUB_USER set as Codespaces secrets
bash scripts/bootstrap.sh                            # kind + SOPS key + Flux
flux get kustomizations --watch
```

OpenBao (once Flux shows `apps-openbao` Ready; details in
[`docs/runbooks/openbao-init-unseal.md`](docs/runbooks/openbao-init-unseal.md)):

```bash
bash scripts/openbao-deploy-check.sh   # 3 pods Running, sealed, tables in PostgreSQL
bash scripts/openbao-init.sh           # once: keys to ~/openbao-init.json + Codespaces secrets
bash scripts/openbao-unseal.sh         # after every pod/Codespace restart
bash scripts/openbao-configure.sh      # once: KV v2, Kubernetes auth, ESO policies and role
bash scripts/openbao-evidence.sh       # evidence in docs/evidence/04-*.txt
bash scripts/openbao-failover-test.sh  # deletes the active pod (asks first)
```

Check everything (read-only; includes monitoring: targets up, alert rules
loaded, nothing firing; details in
[`docs/runbooks/monitoring.md`](docs/runbooks/monitoring.md)):

```bash
bash scripts/test-gate.sh
bash scripts/monitoring-check.sh
```

## Starting and unsealing OpenBao

OpenBao keeps its data encrypted. After every start it is **sealed**: it
cannot read its own data until 3 of the 5 key shares are entered.

```mermaid
flowchart TB
  you([You])
  init[scripts/openbao-init.sh<br/>once per new OpenBao]
  unseal[scripts/openbao-unseal.sh<br/>after every restart]
  conf[scripts/openbao-configure.sh<br/>once]
  keys[(Codespaces secrets<br/>and ~/openbao-init.json<br/>5 key shares, root token)]
  api[Kubernetes API]
  bao[OpenBao pods<br/>start sealed]

  you -->|"runs"| init
  you -->|"runs"| unseal
  you -->|"runs"| conf
  init -->|"saves the shares and the root token"| keys
  unseal -->|"reads 3 shares"| keys
  conf -->|"reads the root token"| keys
  init -->|"kubectl exec: bao operator init"| api
  unseal -->|"kubectl exec: one share at a time, via stdin"| api
  conf -->|"kubectl exec: storage, logins, policies"| api
  api -->|"runs the bao command inside the pod"| bao
```

How to read it: an arrow points from the one who starts the call to the one who
is asked. The scripts never call OpenBao over the network; they run the `bao`
command inside a pod through `kubectl exec`, and pass keys and tokens through
stdin, never on the screen or the command line. `openbao-configure.sh` sets up
the secret storage (KV v2), the Kubernetes login for ESO, and the policies in
[`openbao/policies/`](openbao/policies/). Runbook:
[`docs/runbooks/openbao-init-unseal.md`](docs/runbooks/openbao-init-unseal.md).

## Production-ready vs simplified for the demo

| Topic | Demo | Production |
| --- | --- | --- |
| Unseal | Shamir: 5 key shares, threshold 3, manual `scripts/openbao-unseal.sh` after every pod restart | Auto-unseal with a cloud KMS or an HSM |
| Unseal keys | All shares in one Codespaces secret (and `~/openbao-init.json`) | Shares split between different people, never in one place |
| Cluster | One kind cluster in one Codespace (4 node containers on one VM) | Several nodes in several zones |
| Backup storage | SeaweedFS inside the same cluster | S3 outside the cluster, in another region or account |
| TLS | Self-signed demo CA through cert-manager | Company CA or ACME |
| Root token | Used for init and configuration; still valid, revoke with `scripts/openbao-revoke-root.sh` | Break-glass only, generated when needed and revoked again |
| Access | Kubernetes auth with least-privilege policies (done) | Same |
| NetworkPolicies | Default-deny ingress in `storage`, `databases`, `openbao`, `external-secrets`, `eso-demo` (done); the metrics ports are open only to the Prometheus pod. No egress policies. No policies in the other namespaces | Ingress and egress policies in every namespace |
| Audit | OpenBao audit device to stdout (the pod log) | Audit log shipped to a log system |
| Monitoring and alerting | Prometheus and Alertmanager (1 replica each), 8 alerts (seal status, ESO sync and store, PostgreSQL health, backup age, nodes); no receiver, alerts are only visible (done) | 2 replicas, a receiver (mail/on-call), longer retention, dashboards; also certificate-expiry alerts |
| Secrets in Git | SOPS + age (done); the age key is a Codespaces secret | age key in a KMS or an external secret manager |

## Secret synchronization demo

External Secrets Operator (chart 2.14.0) connects to OpenBao through one
`ClusterSecretStore` `openbao`: HTTPS to `openbao-active.openbao.svc:8200`
(listener certificate from the demo CA), login with Kubernetes auth as service
account `external-secrets/external-secrets` (role `external-secrets`,
policies in [`openbao/policies/`](openbao/policies/)). No root or static token.
Manifests: [`apps/external-secrets/`](apps/external-secrets/), layer
`apps-external-secrets`.

- **Pull**: `ExternalSecret eso-demo/hello` copies `secret/demo/hello` (field
  `message`) to the Secret `eso-demo/hello-from-openbao` every 30 s.
- **Push**: `PushSecret eso-demo/push-demo` copies the demo Secret
  `eso-demo/push-demo` to `secret/pushed/push-demo` (`updatePolicy: Replace`,
  `deletionPolicy: Delete`).
- **Least privilege**: the ESO login can read `secret/`, write only below
  `secret/pushed/`; the refresh test changes values with a separate
  `demo-writer` login.

How one sync works, step by step (the ESO controller logs in again for every sync):

```mermaid
sequenceDiagram
  participant ESO as ESO controller
  participant API as Kubernetes API
  participant Bao as OpenBao (active pod)
  ESO->>API: give me a 10-minute token for service account external-secrets
  API-->>ESO: token
  ESO->>Bao: log in with this token, role external-secrets
  Bao->>API: is this token real? (TokenReview, as OpenBao's own service account)
  API-->>Bao: yes, it is external-secrets/external-secrets
  Bao-->>ESO: OpenBao token with the policies eso-read and eso-write
  Note over ESO,Bao: pull (every 30 s)
  ESO->>Bao: read secret/demo/hello
  ESO->>API: create or update Secret eso-demo/hello-from-openbao
  Note over ESO,Bao: push (every 30 s)
  ESO->>API: read Secret eso-demo/push-demo
  ESO->>Bao: write secret/pushed/push-demo
```

How to read it: time runs from top to bottom. A solid arrow is a call, a dashed
arrow is its answer.

```bash
bash scripts/eso-store-check.sh      # store Valid / Ready
bash scripts/eso-pull-check.sh       # pulled value
bash scripts/eso-refresh-test.sh     # change in OpenBao reaches Kubernetes
bash scripts/eso-push-check.sh       # pushed value read back from OpenBao
bash scripts/eso-evidence.sh         # all of it -> docs/evidence/05-external-secrets.txt
```

Evidence: [`docs/evidence/05-external-secrets.txt`](docs/evidence/05-external-secrets.txt).
Runbook: [`docs/runbooks/external-secrets.md`](docs/runbooks/external-secrets.md).

## Backup and restore

```mermaid
flowchart LR
  subgraph databases[namespace databases]
    pg[(pg-openbao<br/>3 PostgreSQL pods,<br/>Barman Cloud plugin in each)]
    restore[(pg-restore<br/>a NEW cluster,<br/>only when you restore)]
  end
  s3[(SeaweedFS S3<br/>bucket pg-backups<br/>kept 7 days)]
  pg -->|"WAL: every change, all the time"| s3
  pg -->|"base backup: a full copy, daily 12:00 UTC"| s3
  restore -->|"reads a base backup and the WAL<br/>up to the chosen time"| s3
```

How to read it: an arrow points from the pod that starts the call to the one
that is asked. The live cluster only writes to S3; a restore cluster only
reads from it (it has no WAL archiving of its own, so it can never overwrite
the live cluster's backups). Example restore cluster:
[`docs/runbooks/restore-example.yaml`](docs/runbooks/restore-example.yaml).

- The `ScheduledBackup` `pg-openbao-daily` takes a base backup every day at
  12:00 UTC (13:00 Berlin in winter), cron `"0 0 12 * * *"`
  ([`apps/database/backups.yaml`](apps/database/backups.yaml)). A slot missed
  while the Codespace is stopped runs as soon as the cluster runs again.
- Backups go through the Barman Cloud plugin to `s3://pg-backups/` on
  SeaweedFS; WAL is archived continuously; retention 7 days
  ([`apps/database/objectstore.yaml`](apps/database/objectstore.yaml)).
- Point-in-time recovery always goes into a **new** cluster, never over the
  live one. Runbook:
  [`docs/runbooks/postgres-backup-restore.md`](docs/runbooks/postgres-backup-restore.md).

```bash
bash scripts/failure-f6-restore.sh                                # tested PITR into a temporary cluster
kubectl -n databases get backups --sort-by=.metadata.creationTimestamp
```

A restore cluster needs NetworkPolicy access for the CloudNativePG operator to
its instance manager (port 8000): `allow-instance-manager` in
[`apps/database/networkpolicy.yaml`](apps/database/networkpolicy.yaml) now
selects every CloudNativePG instance (`cnpg.io/podRole: instance`), not only
`pg-openbao`.

## Operations

Daily scripts, the known problem after a Codespace restart, monitoring and alerts: [`docs/operations.md`](docs/operations.md).

## Failure tests

All tests ran in the Codespace on 2026-10-27 and 2026-10-28. Details:
[`docs/runbooks/failure-tests.md`](docs/runbooks/failure-tests.md).

| Test | What we break | Result | Recovery time | Evidence file |
| --- | --- | --- | --- | --- |
| F1 | Worker node with the active OpenBao pod and the PostgreSQL primary (`docker stop`) | OpenBao answered again through a standby; the restarted pod came back sealed | OpenBao 76 s (54 s until the node was seen as lost, 7 s PostgreSQL promotion, 15 s until OpenBao answered) | [`07-f1-worker-node.txt`](docs/evidence/07-f1-worker-node.txt) |
| F2 | PostgreSQL primary pod deleted | Replica promoted; OpenBao writes failed only about 4-6 s | Failover 187 s (180 s smart shutdown); healthy after 213 s | [`07-f2-postgres.txt`](docs/evidence/07-f2-postgres.txt) |
| F3 | All OpenBao pods restarted (sealed) while ESO runs | Kubernetes Secret kept its value; ESO recovered by itself after unseal | ExternalSecret Ready 16 s after unseal | [`07-f3-sealed.txt`](docs/evidence/07-f3-sealed.txt) |
| F4 | PushSecret deleted (Flux paused) | Value and all versions deleted in OpenBao; Flux recreated the PushSecret | Deleted after 1 s; back 2 s after Flux resumed | [`07-f4-pushsecret.txt`](docs/evidence/07-f4-pushsecret.txt) |
| F5 | ESO controller pod deleted | New pod logged in with new tokens; Secret untouched | New pod 1 s; synced 6 s | [`07-f5-eso-restart.txt`](docs/evidence/07-f5-eso-restart.txt) |
| F6 | Point-in-time restore into a new cluster | Restored exactly to the target time | Restore cluster healthy after 71 s | [`07-f6-restore.txt`](docs/evidence/07-f6-restore.txt) |

## Limitations and next steps

Risk assessment with risk matrix: [`docs/risk-assessment.md`](docs/risk-assessment.md).

- Unseal is manual: every OpenBao pod restart needs `scripts/openbao-unseal.sh`.
- Backup storage is inside the same cluster: losing the Codespace loses data and backups.
- Single cluster in one Codespace; the HA design only covers pod and node-container failures.
- Monitoring is minimal: one Prometheus and one Alertmanager, no receiver (nobody is notified), 2 days of metrics, PostgreSQL metrics unencrypted on the pod network (R30, R31).
- The OpenBao root token is still valid: revoke it with `scripts/openbao-revoke-root.sh`.
- Flux and GitHub tokens, Codespaces secrets and the deploy key must be revoked after the review (checklist in [`docs/environment.md`](docs/environment.md)).
- Nothing was load-tested.

## Time spent

See [`docs/time-log.md`](docs/time-log.md).
