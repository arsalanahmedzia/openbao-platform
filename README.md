# OpenBao Platform

Production-oriented Kubernetes platform with OpenBao as the secrets management system, a highly available PostgreSQL backend, External Secrets Operator for bidirectional secret synchronization, and Flux for GitOps.

> Status: work in progress

## Overview

_TODO: one paragraph + architecture diagram._

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

## Components and versions

| Component | Purpose | Version |
| --- | --- | --- |
| kind | Local multi-node Kubernetes cluster | TODO |
| Flux | GitOps engine | TODO |
| SOPS + age | Encrypted bootstrap secrets in Git | TODO |
| cert-manager | TLS certificates (self-signed CA) | TODO |
| Traefik | HTTPS entry point (ingress) | chart 42.1.3 |
| SeaweedFS | In-cluster S3 for PostgreSQL backups | 4.48 (image) |
| CloudNativePG | HA PostgreSQL with backups | operator 1.30.1 (chart 0.29.1), PostgreSQL 18.6, plugin-barman-cloud 0.15.1 (chart 0.8.1) |
| OpenBao | Secrets management (HA, PostgreSQL backend) | 2.7.1 (chart 0.30.4) |
| External Secrets Operator | Secret sync OpenBao <-> Kubernetes | 2.14.0 (chart and app) |

## Architecture and design decisions

_TODO: summary of each ADR, see [`docs/adr/`](docs/adr/)._

- [ADR 0001](docs/adr/0001-pinned-versions.md): pin exact chart and image versions.
- [ADR 0002](docs/adr/0002-in-cluster-s3.md): in-cluster S3 with SeaweedFS for PostgreSQL backups.
- [ADR 0003](docs/adr/0003-cloudnativepg-ha.md): HA PostgreSQL with CloudNativePG, backups through the Barman Cloud plugin.
- [ADR 0004](docs/adr/0004-openbao-ha-postgresql.md): OpenBao HA on PostgreSQL, manual Shamir unseal, TLS at Traefik.
- [ADR 0005](docs/adr/0005-external-secrets-openbao.md): External Secrets with one ClusterSecretStore, TLS on the OpenBao listener, Kubernetes auth, push/pull policies.

## Production-ready vs simplified for the demo

_TODO_

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

_TODO: see [`docs/runbooks/`](docs/runbooks/)._

## Operations: monitoring, alerting, troubleshooting

_TODO: see `docs/operations.md`._

## Limitations and next steps

_TODO_

## Time spent

See [`docs/time-log.md`](docs/time-log.md).
