# Scripts

Every script explains at the top what it does, step by step, with the real
commands. They print PASS / FAIL / INFO lines with UTC times and never print
keys or tokens. Run them from the repository root, for example
`bash scripts/verify/test-gate.sh`. Scripts for daily use are listed in
[`docs/operations.md`](../docs/operations.md); failure tests in
[`docs/runbooks/failure-tests.md`](../docs/runbooks/failure-tests.md).

## Start the platform, full order

The README shows the five main commands. This is the full order, as it was
used (demo environment: a GitHub Codespace, see `docs/environment.md`).

```bash
# in a Codespace created from this repo (tools install automatically);
# secrets SOPS_AGE_KEY, FLUX_GITHUB_TOKEN, GITHUB_USER set as Codespaces secrets
bash scripts/setup/bootstrap.sh                       # kind + SOPS key + Flux
flux get kustomizations --watch
```

OpenBao (once Flux shows `apps-openbao` Ready; details in
`docs/runbooks/openbao-init-unseal.md`):

```bash
bash scripts/openbao/openbao-deploy-check.sh          # 3 pods Running, sealed, tables in PostgreSQL
bash scripts/openbao/openbao-init.sh                  # once: keys to ~/openbao-init.json + Codespaces secrets
bash scripts/after-restart/openbao-unseal.sh          # after every pod/Codespace restart
bash scripts/openbao/openbao-configure.sh             # once: KV v2, Kubernetes auth, ESO policies and role
bash scripts/openbao/openbao-evidence.sh              # evidence in docs/evidence/04-*.txt
bash scripts/failure-tests/openbao-failover-test.sh   # deletes the active pod (asks first)
```

Check everything (read-only; includes monitoring: targets up, alert rules
loaded, nothing firing; details in `docs/runbooks/monitoring.md`):

```bash
bash scripts/verify/test-gate.sh
bash scripts/monitoring/monitoring-check.sh
```

## Folders

| Folder | What is in it | Changes the cluster? |
| --- | --- | --- |
| [`setup/`](setup/) | Install the tools, create the cluster, generate the SOPS files (once) | yes, once |
| [`after-restart/`](after-restart/) | Bring the cluster back, repair the pod network, unseal OpenBao | yes |
| [`verify/`](verify/) | `test-gate.sh` (the whole platform) and `github-access.sh` | no |
| [`openbao/`](openbao/) | Deploy check, init, configure, policies, rollout, audit, evidence, root token, Traefik check | yes |
| [`external-secrets/`](external-secrets/) | Store, pull, refresh, push, evidence, debug | mostly reconcile and read |
| [`database/`](database/) | PostgreSQL health and replication, S3 storage, backups | test data, removed again |
| [`monitoring/`](monitoring/) | `monitoring-check.sh` (daily, read-only) and the stage checks M1 to M3 | the stage checks do |
| [`hardening/`](hardening/) | One NetworkPolicy test per namespace | temporary test pods |
| [`failure-tests/`](failure-tests/) | F1 to F6 and the OpenBao failover; each asks before it breaks anything | yes, on purpose |

Proving an alert: `failure-f3-sealed.sh` takes `F3_WATCH_ROUNDS` (15 s rounds
before the unseal, default 8) and `F3_OUT` (evidence file); see
`docs/runbooks/monitoring.md`, section 5.

## Old paths

Until 2026-10-29 all scripts were directly in `scripts/`. The `Command:` lines
in `docs/evidence/` are recorded outputs and keep the old paths. Each old path
`scripts/<name>` is now `scripts/<folder>/<name>`:

| Folder | Scripts |
| --- | --- |
| `setup/` | install-tools, bootstrap, kind-config.yaml, pin-versions, s3-secrets, openbao-db-secret, sops-demo |
| `after-restart/` | resume, kind-fix-pod-network, openbao-unseal |
| `verify/` | test-gate, github-access-check (now named github-access.sh) |
| `openbao/` | openbao-deploy-check, openbao-init, openbao-configure, openbao-policy-update, openbao-tls-rollout, openbao-audit-check, openbao-evidence, openbao-generate-root, openbao-revoke-root |
| `external-secrets/` | eso-store-check, eso-pull-check, eso-refresh-test, eso-push-check, eso-evidence, eso-debug |
| `database/` | pg-backup-check (new on 2026-10-29: pg-check, storage-check) |
| `monitoring/` | monitoring-check, monitoring-deploy-check, monitoring-openbao-metrics, monitoring-cnpg-metrics, monitoring-eso-metrics, monitoring-netpol-check |
| `hardening/` | netpol-enforcement-test, netpol-test-storage, netpol-test-databases, netpol-test-openbao, netpol-test-external-secrets, netpol-test-eso-demo |
| `failure-tests/` | failure-f1-worker … failure-f6-restore, openbao-failover-test |
