# Task: OpenBao in HA mode on PostgreSQL, initialised, unsealed and configured

Read CLAUDE.md first and follow its rules (plain, detailed explanations, no analogies; never
print secrets; ask before anything destructive; everything lasting through Git/Flux; pin
versions; do not guess, verify, and say when unsure; no attribution lines in commits).
Work like the S3 and PostgreSQL stages: explain each file BEFORE creating it, small commits
(`git add` named files), evidence files, runbook, ADR, time-log line.
The user has read the concepts (seal/unseal, active/standby, Kubernetes auth, KV v2, policies).
Explain commands in plain words when you run them.

## Goal
Three OpenBao pods (one active, two standby) that store their data in the PostgreSQL cluster
`pg-openbao` (database `openbao`), reachable over HTTPS through Traefik, initialised and
unsealed, with KV v2, Kubernetes auth and policies ready for External Secrets (next stage;
do NOT install or configure External Secrets resources now).

## Already in the cluster
Flux layers: infra-controllers, infra-configs (cert-manager ClusterIssuer `demo-ca`, SOPS),
infra-storage, apps-database. PostgreSQL `pg-openbao` in namespace `databases` (3 instances,
service `pg-openbao-rw`, database `openbao`, owner `openbao`, operator-generated Secret
`databases/pg-openbao-app`). Traefik listens on host ports 80/443 on the control-plane node.

## Design decisions
1. New Flux layer `apps-openbao` in `clusters/demo/`, folder `apps/openbao/`, dependsOn
   `apps-database` and `infra-configs`, `wait: true`, SOPS decryption block like the others.
   Namespace `openbao`.
2. Helm: add a HelmRepository for the official OpenBao chart and a HelmRelease with an EXACT
   pinned chart version and a pinned image tag. Find the chart repo URL, chart name and current
   stable versions yourself (check the official OpenBao docs / `helm search repo`) and say how you
   verified. Use `helm show values` to find the real value names. Do not guess values.
3. HA: 3 replicas, required pod anti-affinity (one per worker), PostgreSQL storage backend with
   HA enabled (the HA lock table in PostgreSQL). Verify the exact storage stanza and option names
   (`ha_enabled`, `table`, `ha_table`, connection string) in the OpenBao docs for the pinned version.
   Disable the integrated Raft storage and the Vault-style dev mode.
4. Database password path. The Secret `databases/pg-openbao-app` cannot be read from namespace
   `openbao`. ASK THE USER with AskUserQuestion which to use, explaining each in plain words:
   (a) Recommended: declare the `openbao` role in the Cluster (`spec.managed.roles` with
       `passwordSecret`) using a SOPS-encrypted password Secret in `databases`, and put the same
       password in a SOPS-encrypted Secret in `openbao` holding the connection URL (same pattern as the
       S3 credentials; script generates the password, never prints it);
   (b) read the operator's Secret from another namespace with a External Secrets Operator
       Kubernetes-provider store (more moving parts);
   (c) copy it by hand (not acceptable: not GitOps).
   Check that changing the role password on the running cluster is supported and does not
   recreate the cluster; say what you verified.
5. Configuration of the OpenBao connection string: prefer passing it by an environment variable
   from the Secret (verify the supported variable name for the PostgreSQL backend) so the password is
   not written into a ConfigMap.
6. TLS: listener inside the cluster stays plain HTTP for the demo (record in ADR). Add a cert-manager
   Certificate from ClusterIssuer `demo-ca` and a Traefik Ingress (use the chart's ingress values if
   they exist; otherwise a plain Ingress) for host `openbao.demo.local` with HTTPS. Verify with
   `curl --resolve openbao.demo.local:443:127.0.0.1 --cacert <ca> https://openbao.demo.local/v1/sys/health`
   from the Codespace. Tell the user how to reach the UI (kubectl port-forward as fallback).
7. Resources: small (requests about 100m CPU / 128Mi, limit 256Mi; check it is stable on 16 GB).
8. Readiness: a sealed pod is not Ready, so with `wait: true` Flux will wait forever before init.
   Choose a design that avoids a deadlock (for example do not put sealed pods under `wait`, or use
   health checks only for the Deployment/StatefulSet existing; or readiness that accepts sealed
   state `sealedcode`/`uninitcode` as the chart allows). Verify chart options and explain the choice.

## Init and unseal (scripts, never in Git with secrets)
- `scripts/openbao-init.sh`: run `bao operator init` (5 shares, threshold 3) inside one pod via
  `kubectl exec`, with JSON output written straight to a file outside the repo (`~/openbao-init.json`,
  `chmod 600`, umask 077). NEVER echo, cat or log the keys or the root token. Output only: "initialised,
  keys saved to <path>".
- Then unseal all 3 pods by reading the shares from that file (use jq; no values on the command
  line or in the process list where avoidable: feed via stdin).
- Store the shares and root token as Codespaces secrets (`gh secret set OPENBAO_UNSEAL_KEYS` and
  `OPENBAO_ROOT_TOKEN` from the file via stdin) so a new Codespace can unseal. Tell the user to also
  keep the file somewhere safe outside the Codespace (download it from the editor; it must not
  enter Git). Remind to add `openbao-init.json` to .gitignore as a safety net.
- `scripts/openbao-unseal.sh`: unseal every pod using the Codespaces secrets in the environment.
  Add a call or a printed hint to `scripts/resume.sh` (pods restart sealed).
- All three pods must show `Initialized true`, `Sealed false`; exactly one active, two standby.

## Configuration inside OpenBao (script, run once, idempotent where possible)
`scripts/openbao-configure.sh` (uses the root token from the environment via `kubectl exec`
with the token passed through stdin/env, never printed):
- enable KV v2 at `secret/`;
- enable the Kubernetes auth method and configure it for in-cluster use (verify required
  fields: `kubernetes_host`, token reviewer; check which service account needs `system:auth-delegator`
  and add the ClusterRoleBinding via Flux if the chart does not);
- policies: `eso-read` (read/list `secret/data/*` and `secret/metadata/*`) and `eso-write`
  (create/update on `secret/data/pushed/*`);
- Kubernetes auth role `external-secrets` bound to the External Secrets service account name and
  namespace (check the real names in the cluster: `kubectl -n external-secrets get sa`), policies
  `eso-read` and `eso-write`, short TTL;
- write one test secret `secret/demo/hello` and read it back;
- afterwards do NOT use the root token again; mention revoking it as a hardening step in the ADR.
Note in the ADR/runbook that OpenBao's internal configuration is not stored in Git and how it
would be managed in production (for example the OpenTofu/Terraform provider or a config operator).

## Tests (evidence in docs/evidence/04-*.txt, never include keys/tokens)
1. `kubectl -n openbao get pods -o wide`: 3 pods, 3 different workers, all Ready after unseal.
2. `bao status` for each pod (Initialized, Sealed, HA Enabled, HA Mode active/standby).
3. HTTPS health through the ingress.
4. Failover: delete the ACTIVE pod; show a standby becomes active; the secret is still readable;
   the replacement pod comes back SEALED, then run the unseal script and show it joins as standby.
   (Do not stop nodes; the node-failure test is a later stage.)
5. PostgreSQL side: show OpenBao tables exist in database `openbao` (`kubectl cnpg psql` with a
   `\dt`, no data dump), and that a backup still completes after OpenBao started writing
   (`kubectl cnpg backup pg-openbao -n databases`, show phase).
6. Restore sanity (optional, only if time allows): not required now.

## Docs
- Runbook `docs/runbooks/openbao-init-unseal.md`: first start, restart (re-unseal), pod failure,
  lost keys (what is and is not recoverable), rotating the root token.
- ADR `docs/adr/0004-openbao-ha-postgresql.md`: PostgreSQL vs Raft storage (the task requires
  PostgreSQL), HA via PostgreSQL lock, manual Shamir unseal vs auto-unseal, plain HTTP inside the
  cluster, trade-offs, what production would change.
- Update README only for what changed; append to docs/time-log.md.
- End with 5 plain sentences the user should be able to explain, and a list of things you were unsure about.

## Safety checklist (verify before every commit)
`git diff --cached` shows no keys, tokens, passwords or connection URLs with passwords; only
`*.sops.yaml` files hold secrets and they are encrypted (`ENC[`); `git status` shows no
`openbao-init.json`.