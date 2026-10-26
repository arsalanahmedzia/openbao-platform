# ADR 0004: OpenBao in HA mode on PostgreSQL, manual Shamir unseal

- Status: accepted
- Date: 2026-10-26

## Problem

OpenBao is the secrets store of the platform. It must survive the loss of one
pod or node, keep its data in the HA PostgreSQL cluster `pg-openbao` (the task
requires PostgreSQL storage), be reachable over HTTPS through Traefik, and be
ready for External Secrets (KV v2, Kubernetes auth, policies). Everything that
can be in Git is deployed by Flux; the unseal keys and root token must never
be in Git.

## Options

**Storage**
1. Integrated Raft storage: OpenBao replicates its own data between pods
   (volume per pod, leader election built in). No external database, but a
   second replicated data store to back up and operate.
2. **PostgreSQL storage backend** (required by the task): all pods share one
   database; data, backups and point-in-time recovery come from CloudNativePG
   (ADR 0003).

**HA coordination with PostgreSQL**
1. One pod only: no HA.
2. **`ha_enabled = "true"`**: every pod tries to hold a lock row in the table
   `openbao_ha_locks`; the holder is *active*, the others are *standby* and
   forward requests to it. If the active pod stops renewing the lock, a standby
   takes it over.

**Unseal**
1. **Manual Shamir unseal**: the key that decrypts all data is split into 5
   shares; 3 must be entered into every pod after every start.
2. Auto-unseal: the key is protected by an external key service (a cloud KMS,
   an HSM, or another OpenBao's transit engine); pods unseal themselves.
   Needs that external service, which the demo environment does not have.

**Database password for OpenBao** (it cannot read Secrets in `databases`)
1. **SOPS: one generated password in two encrypted Secrets**, the Cluster takes
   it through `bootstrap.initdb.secret`.
2. Same, but through `spec.managed.roles[].passwordSecret`.
3. External Secrets Kubernetes provider copying `pg-openbao-app` across
   namespaces.
4. Copy by hand: not GitOps.

**TLS**
1. End-to-end TLS (OpenBao listener with its own certificate).
2. **TLS terminated at Traefik**, plain HTTP inside the cluster.

## Choice

- Chart `openbao/openbao` 0.30.4 (official repository
  `https://openbao.github.io/openbao-helm`, digest checked against its
  `index.yaml`), image `quay.io/openbao/openbao:2.7.1` (published 2026-10-01).
  Values checked in the chart's `values.yaml` and templates.
- **3 replicas, HA via the PostgreSQL lock**, Raft and dev mode off.
  Storage stanza (option names and defaults checked in the v2.7.1 source,
  `internal/physical/postgresql/postgresql.go`):
  `ha_enabled = "true"`, `table = "openbao_kv_store"`,
  `ha_table = "openbao_ha_locks"`. OpenBao creates both tables itself.
- **Connection string from the environment**: `BAO_PG_CONNECTION_URL` from the
  SOPS Secret `openbao/openbao-db` (overrides `connection_url`), so the password
  is not in the ConfigMap that holds the config file.
- **Password option 1.** CloudNativePG's instance manager applies the
  application owner's password from `GetApplicationSecretName()`, which is
  `bootstrap.initdb.secret` if set, otherwise the generated `pg-openbao-app`.
  It remembers what it applied only in memory, so it re-applies after every
  restart or failover. With option 2 both `pg-openbao-app` and the managed-role
  Secret would set the password of the same role, and after a PostgreSQL
  failover the generated one could win. Option 1 leaves one source. The
  validating webhook does not block changes to `bootstrap`, and `initdb`
  itself only runs at creation, so the running cluster was not rebuilt (seen:
  OpenBao connected and created its tables right after the change).
- **Required pod anti-affinity** on `kubernetes.io/hostname` (chart default):
  one pod per worker, so one node failure takes out at most one pod.
- **Shamir unseal, 5 shares, threshold 3**, done by `scripts/openbao-init.sh`
  and `scripts/openbao-unseal.sh`. Keys and root token go to
  `~/openbao-init.json` (outside the repo, `chmod 600`, in `.gitignore` as a
  safety net) and to Codespaces secrets; they are passed to pods through
  stdin, never printed or put on a command line.
- **Readiness without a deadlock**: the chart's readiness check is
  `bao status`, which fails while a pod is sealed, so Ready means unsealed.
  Helm would wait forever for Ready pods before anyone can unseal, so the
  HelmRelease sets `install.disableWait` / `upgrade.disableWait`, and
  `podManagementPolicy: Parallel` starts all pods at once (the default
  OrderedReady would not create pod 1 before pod 0 is Ready). The Flux
  Kustomization keeps `wait: true`: it only waits for the objects it applies
  itself (HelmRelease, Certificate, Secret), not for the pods.
- **TLS terminated at Traefik** with a cert-manager certificate from
  `demo-ca` for `openbao.demo.local`; the Ingress points at the Service
  `openbao-active`, which `service_registration "kubernetes"` keeps on the
  active pod.
- **Configuration inside OpenBao** (KV v2 at `secret/`, Kubernetes auth,
  policies `eso-read` / `eso-write`, role `external-secrets`) by
  `scripts/openbao-configure.sh`, run once with the root token. Kubernetes auth
  uses OpenBao's own service account to review tokens; the chart binds it to
  `system:auth-delegator`.

Measured on 2026-10-26 (evidence `docs/evidence/04-*.txt`): active pod deleted
-> a standby became active after about 7 s, the test secret was readable
before and after; the recreated pod started sealed and joined as standby after
unseal. A base backup of `pg-openbao` completed with OpenBao writing to it.

## Trade-offs

- **Manual unseal**: every pod restart (crash, node failure, upgrade,
  Codespace restart) leaves that pod sealed until someone runs the unseal
  script. With all pods sealed OpenBao is down. Production: auto-unseal with a
  KMS/HSM, so that no person holds key shares day to day.
- **Keys in a file and Codespaces secrets**: convenient for the demo, but one
  person holds all 5 shares, which defeats the point of splitting the key.
  Production: give shares to different people (or use PGP-encrypted shares),
  or use auto-unseal with recovery keys.
- **Plain HTTP inside the cluster**: anyone who can capture pod network traffic
  can read tokens and secrets between Traefik and OpenBao (and between ESO and
  OpenBao). Production: TLS on the OpenBao listener (cert-manager certificate,
  `tlsDisable: false`) and a NetworkPolicy that only lets Traefik and ESO in.
- **`sslmode=require`** to PostgreSQL encrypts but does not verify the server
  certificate. Production: `verify-full` with the CloudNativePG CA.
- **Configuration not in Git**: mounts, auth methods, policies and roles live
  in OpenBao's storage, not in Git, so Flux cannot detect drift or recreate
  them. Production: manage them declaratively, for example with the OpenTofu /
  Terraform Vault provider (works with OpenBao's API) in a pipeline, or a
  configuration operator.
- **Root token**: still valid after configuration. Hardening step: revoke it
  (`bao token revoke -self`) and create a new one only when needed with
  `bao operator generate-root` and a quorum of key shares (see runbook).
- **`updateStrategyType: OnDelete`** (chart default): a config change in Git
  updates the StatefulSet but not the running pods; someone deletes pods one
  by one (standbys first, active last) and unseals each.
- **One database for everything**: if `pg-openbao` is down, OpenBao is down
  (standbys cannot serve without storage). Its availability and recovery are
  those of ADR 0003.
- **Demo sizing**: 100m CPU / 128Mi request, 256Mi limit per pod, no audit log
  device. Production: an audit device (file on a volume or socket to a log
  system), monitoring of seal status and the lock, more memory.
