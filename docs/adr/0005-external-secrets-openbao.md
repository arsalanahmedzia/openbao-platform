# ADR 0005: External Secrets with OpenBao: one ClusterSecretStore, TLS, Kubernetes auth

- Status: accepted
- Date: 2026-10-26

## Problem

Applications in the cluster need secrets from OpenBao as normal Kubernetes
Secrets (pull), and some values created in Kubernetes must be stored in
OpenBao (push). The External Secrets Operator (ESO, chart 2.14.0, already
installed by Flux) does both. Open questions: how many stores, how ESO
reaches and trusts OpenBao, how it logs in, how often it refreshes, what
OpenBao lets it do, and what happens when objects are deleted. No root token
and no long-lived static token may be used.

## Options

**Store scope**
1. **One `ClusterSecretStore`**, restricted with `spec.conditions` to the
   namespaces that may use it.
2. A `SecretStore` per namespace: stronger isolation, but each needs a
   service account in its own namespace and its own OpenBao role and policy.

**Connection and trust** (the OpenBao listener was plain HTTP, ADR 0004)
1. In-cluster HTTP (`http://openbao-active.openbao.svc:8200`), no CA:
   ESO's login token and the secret values cross the pod network unencrypted.
2. **TLS on the OpenBao listener** with a certificate from `demo-ca`, ESO
   uses `https://openbao-active.openbao.svc:8200` and trusts the demo CA.
3. The Traefik hostname `openbao.demo.local`: does not resolve inside the
   cluster without a DNS rewrite, and adds a hop.

**Login**
1. Static token in a Kubernetes Secret: long-lived, must be rotated by hand,
   gives access to anyone who can read that Secret.
2. **Kubernetes auth**: ESO asks Kubernetes for a short-lived token of its own
   service account and exchanges it for a short-lived OpenBao token.

**Refresh interval**: 15 s, **30 s**, 1 m (production often 1 h).

**PushSecret `deletionPolicy`**: `None` (value stays in OpenBao) or
**`Delete`** (value removed from OpenBao with the PushSecret).

**How the refresh test changes a value under `secret/demo/`**: as ESO
(needs write rights there), as root, or as a **separate `demo-writer` login**.

## Choice

- **One `ClusterSecretStore` `openbao`**, `conditions` limited to namespace
  `eso-demo`. A namespaced `SecretStore` could not log in as
  `external-secrets/external-secrets`, which the task requires.
- **TLS on the OpenBao listener** (option 2): Certificate
  `openbao/openbao-server-tls` from `demo-ca` for the Service names plus
  `localhost`/`127.0.0.1` (the `bao` CLI in each pod uses
  `BAO_ADDR=https://127.0.0.1:8200`; the chart sets no CA, so the HelmRelease
  sets `BAO_CACERT`). `global.tlsDisable: false` switches the chart's probes,
  `BAO_ADDR` and Service port name to `https`. Traefik connects to the pods
  with TLS (port named `https`) through a `ServersTransport` that trusts the
  demo CA and checks the name `openbao-active.openbao.svc` (Traefik connects
  to pod IPs, which are not in the certificate). Rolled out pod by pod with
  `scripts/openbao-tls-rollout.sh` (`OnDelete`, unseal after each restart).
- **Store**: `server: https://openbao-active.openbao.svc:8200`, `path: secret`,
  `version: v2`, `caProvider` = `ca.crt` of `openbao/openbao-server-tls` (read
  at runtime: a rebuilt cluster gets a new CA, so it is not copied into Git).
- **Kubernetes auth, no root or static token**: `mountPath: kubernetes`,
  `role: external-secrets`, `serviceAccountRef` =
  `external-secrets/external-secrets`. ESO requests a 10-minute token for that
  account (TokenRequest API, no extra audience; ESO source
  `providers/v1/vault/auth_kubernetes.go`); OpenBao checks it with the
  TokenReview API and returns a token with `eso-read` + `eso-write`, TTL 15 m.
  `serviceAccountRef.namespace` must be set in a ClusterSecretStore, otherwise
  ESO uses each ExternalSecret's namespace and does not validate the store.
- **Refresh 30 s**, `refreshPolicy: Periodic`: changes show up within about
  30 s (measured 8 to 32 s). ExternalSecret target `creationPolicy: Owner`
  (Flux prune of the ExternalSecret removes its Secret) and
  `deletionPolicy: Retain` (a value deleted in OpenBao does not break the
  apps using the last Secret).
- **PushSecret** `push-demo`: `updatePolicy: Replace` (Kubernetes is the
  source of truth, changes are written again), `deletionPolicy: Delete`
  (OpenBao mirrors Git). ESO only overwrites or deletes values marked
  `managed-by: external-secrets` in their metadata.
- **Policies** (files in `openbao/policies/`):
  - `eso-read`: read/list `secret/data/*` and `secret/metadata/*`.
  - `eso-write`: create, read, update, delete on `secret/data/pushed/*` and
    `secret/metadata/pushed/*`. A push reads the data path, reads and writes
    the metadata (marker), writes the data; a delete removes both
    (`providers/v1/vault/client_push.go`, ESO v2.14.0).
  - `demo-write`: create/update `secret/data/demo/*`, role `demo-writer` for
    service account `eso-demo/demo-writer`. Used only by the refresh test, so
    ESO stays read-only outside `secret/pushed/`.
- **Lesson recorded**: OpenBao (like Vault) does not merge different path
  patterns: for a request only the most specific matching pattern counts.
  `eso-write`'s `secret/data/pushed/*` without `read` therefore hid
  `eso-read`'s `secret/data/*` and every push failed with 403 on the
  existence check. `read` was added to the `pushed/` rules.

Measured on 2026-10-26 (evidence `docs/evidence/05-*.txt`): store `Valid`;
pulled value correct; changes reached Kubernetes in 8 to 32 s; pushed value
readable as the ESO login; ESO login denied writes to `secret/demo/` and
`secret/other/`; all Flux layers `True` after a clean reconcile.

## Trade-offs

- **One ClusterSecretStore** for all namespaces in `conditions`: any
  ExternalSecret in an allowed namespace can read every secret `eso-read`
  allows. Production with several teams: a SecretStore (or a ClusterSecretStore
  with tight `conditions`) per team, each with its own service account, role
  and a policy limited to that team's paths.
- **`eso-read` reads all of `secret/`**: simple for the demo, too wide for
  production (limit it to the paths apps really need).
- **CA from the cluster**: the store depends on the Secret
  `openbao/openbao-server-tls`; ESO reads it with its cluster-wide Secret
  rights (that Secret also holds the server's private key). Production: publish
  only the CA (for example with trust-manager into a ConfigMap) and narrow
  ESO's Secret rights.
- **Certificate renewal**: OpenBao reads the listener certificate at start.
  cert-manager renews it 15 days before expiry (90-day certificate); the pods
  must then be restarted one by one and unsealed (runbook), or OpenBao serves
  the old certificate until it expires.
- **Short refresh** means more logins and reads against OpenBao (two per
  minute per ExternalSecret); fine for one demo secret, not for hundreds.
- **`deletionPolicy: Delete`**: removing the PushSecret from Git deletes the
  value and all its versions in OpenBao for good.
- **Demo source Secret in Git unencrypted** (`push-demo`, value
  `pushed-from-kubernetes`): allowed only because it is a demo value; real
  values go into `*.sops.yaml` or are created by apps.
- **Store readiness depends on OpenBao**: while OpenBao is sealed the store
  and the Flux layer `apps-external-secrets` are not Ready; existing Kubernetes
  Secrets stay as they are, they are just not refreshed.
