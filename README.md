# OpenBao Platform

A Kubernetes platform that stores and hands out secrets safely. It is built
from this Git repository, has a highly available database, backups and
monitoring.

## Overview

- OpenBao is the vault that keeps the secrets; it runs as 3 copies, one is active and the other two wait to take over.
- PostgreSQL is the database where OpenBao saves its data; it runs as 3 copies and is backed up every day.
- External Secrets Operator (ESO) copies secrets between OpenBao and Kubernetes, in both directions.
- Flux builds everything from this repository, so Git is the single source of truth (this way of working is called GitOps).
- Prometheus watches the platform by collecting numbers every 30 s and raises alerts when something breaks.

![How it runs](docs/images/how-it-runs.png)

## How the parts talk to each other

| From | To | Request | Response |
| --- | --- | --- | --- |
| curl (or a browser or script) | Traefik, which forwards to OpenBao | HTTPS request to `openbao.demo.local`, for example `GET /v1/sys/health` | The health status of the active OpenBao pod (JSON with `sealed: false`) |
| ESO | Kubernetes API | Asks for a service-account token for `external-secrets`, valid 10 minutes | The signed token |
| ESO | OpenBao (HTTPS, port 8200) | Login with that token and the role `external-secrets` | An OpenBao token with the policies `default`, `eso-read` and `eso-write`, valid 15 minutes |
| ESO | OpenBao | Pull: reads `secret/demo/hello`. Push: writes `secret/pushed/push-demo` | The secret value, or a confirmation of the write |
| ESO | Kubernetes API | Pull: creates or updates the Secret `eso-demo/hello-from-openbao`. Push: reads the Secret `eso-demo/push-demo` | A confirmation, or the Secret value |
| OpenBao | Kubernetes API | TokenReview: is this token valid, and whose is it? | Yes, it belongs to the service account `external-secrets/external-secrets` |
| OpenBao | PostgreSQL | Its data, encrypted by OpenBao before it is saved | Stored; or the data when OpenBao reads it back |
| PostgreSQL | SeaweedFS (S3) | A base backup every day at 12:00 UTC, and the WAL files continuously | Stored |
| Prometheus | OpenBao, PostgreSQL, ESO | Asks for the metrics every 30 seconds | A text list of numbers (metrics) |
| Flux | GitHub | Fetches the repository every minute | The files |
| Flux | Kubernetes API | Applies the manifests from Git | The status of each object |

Words: [glossary](docs/glossary.md). Build order, certificates, network rules: [architecture](docs/architecture.md).

## Try it

Runs in a GitHub Codespace (4 cores, 16 GB) with a 4-node kind cluster, see [`docs/environment.md`](docs/environment.md).

```bash
bash scripts/setup/bootstrap.sh            # once: kind cluster, SOPS key, Flux; Flux then builds the rest from Git
bash scripts/openbao/openbao-init.sh         # once: creates OpenBao's 5 key shares and root token, stores them safely
bash scripts/after-restart/openbao-unseal.sh       # after every restart: unlocks (unseals) every OpenBao pod with 3 shares
bash scripts/openbao/openbao-configure.sh    # once: secret storage, login for ESO, policies
bash scripts/verify/test-gate.sh            # read-only check of everything; ends with GATE PASSED
```

All other commands and the full order: [`scripts/README.md`](scripts/README.md).

## What we tested

| Test | What we broke | Result |
| --- | --- | --- |
| F1 | A worker node with the active OpenBao pod and the PostgreSQL primary | OpenBao answered again through a standby after 76 s; the restarted pod came back sealed. |
| F2 | The PostgreSQL primary pod | A replica took over after 187 s; OpenBao writes failed for only about 4-6 s. |
| F3 | All 3 OpenBao pods restarted, so they were sealed | The Kubernetes Secret kept its value, and ESO recovered by itself 16 s after the unseal. |
| F4 | The PushSecret, deleted while Flux was paused | The value was deleted in OpenBao; Flux recreated the PushSecret and the value was back 2 s after Flux resumed. |
| F5 | The ESO controller pod | A new pod logged in with new tokens and synced after 6 s; the Secret was untouched. |
| F6 | Point-in-time restore into a new cluster | The restore was exact to the target time; the cluster was healthy after 71 s. |

Details, timelines and evidence: [`docs/runbooks/failure-tests.md`](docs/runbooks/failure-tests.md).

## Production Readiness

| Topic | Demo | Production |
| --- | --- | --- |
| Access | Kubernetes auth with least-privilege policies (done) | Same |
| TLS | Self-signed demo CA through cert-manager | Company CA or ACME |
| Secrets in Git | SOPS + age (done); the age key is a Codespaces secret | age key in a KMS or an external secret manager |
| Root token | Used for init and configuration; still valid, revoke with `scripts/openbao/openbao-revoke-root.sh` | Break-glass only, generated when needed and revoked again |
| NetworkPolicies | Default-deny ingress in `storage`, `databases`, `openbao`, `external-secrets`, `eso-demo` (done); the metrics ports are open only to the Prometheus pod. No egress policies. No policies in the other namespaces | Ingress and egress policies in every namespace |
| Audit | OpenBao audit device to stdout (the pod log) | Audit log shipped to a log system |
| Monitoring and alerting | Prometheus and Alertmanager (1 replica each), 8 alerts (seal status, ESO sync and store, PostgreSQL health, backup age, nodes); no receiver, alerts are only visible (done) | 2 replicas, a receiver (mail/on-call), longer retention, dashboards; also certificate-expiry alerts |
| Unseal | Shamir: 5 key shares, threshold 3, manual `scripts/after-restart/openbao-unseal.sh` after every pod restart | Auto-unseal with a cloud KMS or an HSM |
| Unseal keys | All shares in one Codespaces secret (and `~/openbao-init.json`) | Shares split between different people, never in one place |
| Backup storage | SeaweedFS inside the same cluster | S3 outside the cluster, in another region or account |
| Cluster | One kind cluster in one Codespace (4 node containers on one VM) | Several nodes in several zones |

## Known Limits

- Unseal is manual: every OpenBao pod restart needs `scripts/after-restart/openbao-unseal.sh`.
- Backups are in the same cluster, so losing the Codespace loses the data and its backups.
- Everything runs in one Codespace, so the high availability only covers failures of pods and node containers.
- Monitoring is minimal: one Prometheus, one Alertmanager, no receiver, 2 days of metrics, PostgreSQL metrics unencrypted (R30, R31).
- The OpenBao root token is still valid; revoke it with `scripts/openbao/openbao-revoke-root.sh`.
- The Flux and GitHub tokens, Codespaces secrets and deploy key must be revoked after the review ([`docs/environment.md`](docs/environment.md)).

All risks with their scores: [`docs/risk-assessment.md`](docs/risk-assessment.md).

## Further

- [`docs/architecture.md`](docs/architecture.md): build order, repo map, secrets in Git, certificates, network rules, versions
- [`docs/operations.md`](docs/operations.md): scripts to run after a restart, the problem after a Codespace restart, monitoring and alerts
- [`docs/runbooks/`](docs/runbooks/): step-by-step guides (unseal, External Secrets, backup and restore, monitoring, failure tests)
- [`docs/adr/`](docs/adr/): design decisions and the options that were rejected
- [`docs/risk-assessment.md`](docs/risk-assessment.md): risks, scores and what was done about them
- [`scripts/README.md`](scripts/README.md): every script and the full start order
- [`docs/evidence/`](docs/evidence/): the real output of every test
- [`docs/glossary.md`](docs/glossary.md): every technical word in plain English
- [`docs/time-log.md`](docs/time-log.md): time spent per task
