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
| ingress-nginx | HTTPS entry point | TODO |
| SeaweedFS | In-cluster S3 for PostgreSQL backups | 4.48 (image) |
| CloudNativePG | HA PostgreSQL with backups | operator 1.30.1 (chart 0.29.1), PostgreSQL 18.6, plugin-barman-cloud 0.15.1 (chart 0.8.1) |
| OpenBao | Secrets management (HA, PostgreSQL backend) | 2.7.1 (chart 0.30.4) |
| External Secrets Operator | Secret sync OpenBao <-> Kubernetes | TODO |

## Architecture and design decisions

_TODO: summary of each ADR, see [`docs/adr/`](docs/adr/)._

- [ADR 0001](docs/adr/0001-pinned-versions.md): pin exact chart and image versions.
- [ADR 0002](docs/adr/0002-in-cluster-s3.md): in-cluster S3 with SeaweedFS for PostgreSQL backups.
- [ADR 0003](docs/adr/0003-cloudnativepg-ha.md): HA PostgreSQL with CloudNativePG, backups through the Barman Cloud plugin.
- [ADR 0004](docs/adr/0004-openbao-ha-postgresql.md): OpenBao HA on PostgreSQL, manual Shamir unseal, TLS at Traefik.

## Production-ready vs simplified for the demo

_TODO_

## Secret synchronization demo

_TODO: pull (ExternalSecret) and push (PushSecret), with evidence._

## Backup and restore

_TODO: see [`docs/runbooks/`](docs/runbooks/)._

## Operations: monitoring, alerting, troubleshooting

_TODO: see `docs/operations.md`._

## Limitations and next steps

_TODO_

## Time spent

See [`docs/time-log.md`](docs/time-log.md).
