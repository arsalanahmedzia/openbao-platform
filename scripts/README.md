# Scripts

Every script explains at the top what it does, step by step, with the real
commands. They print PASS / FAIL / INFO lines with UTC times and never print
keys or tokens. Scripts for daily use are listed in
[`docs/operations.md`](../docs/operations.md); failure tests in
[`docs/runbooks/failure-tests.md`](../docs/runbooks/failure-tests.md).

## Start the platform, full order

The README shows the five main commands. This is the full order, as it was
used (demo environment: a GitHub Codespace, see `docs/environment.md`).

```bash
# in a Codespace created from this repo (tools install automatically);
# secrets SOPS_AGE_KEY, FLUX_GITHUB_TOKEN, GITHUB_USER set as Codespaces secrets
bash scripts/bootstrap.sh                            # kind + SOPS key + Flux
flux get kustomizations --watch
```

OpenBao (once Flux shows `apps-openbao` Ready; details in
`docs/runbooks/openbao-init-unseal.md`):

```bash
bash scripts/openbao-deploy-check.sh   # 3 pods Running, sealed, tables in PostgreSQL
bash scripts/openbao-init.sh           # once: keys to ~/openbao-init.json + Codespaces secrets
bash scripts/openbao-unseal.sh         # after every pod/Codespace restart
bash scripts/openbao-configure.sh      # once: KV v2, Kubernetes auth, ESO policies and role
bash scripts/openbao-evidence.sh       # evidence in docs/evidence/04-*.txt
bash scripts/openbao-failover-test.sh  # deletes the active pod (asks first)
```

Check everything (read-only; includes monitoring: targets up, alert rules
loaded, nothing firing; details in `docs/runbooks/monitoring.md`):

```bash
bash scripts/test-gate.sh
bash scripts/monitoring-check.sh
```

## Monitoring

| Script | What it does | Changes the cluster? |
| --- | --- | --- |
| [`monitoring-check.sh`](monitoring-check.sh) | Health check of monitoring through port-forwards: every scrape target up/down, the 8 platform alert rules loaded and healthy, pending/firing alerts in Prometheus and Alertmanager. A firing alert is a FAIL. `--wait-firing <Alert> [minutes]` waits until that alert fires (for failure tests). | No |
| [`monitoring-deploy-check.sh`](monitoring-deploy-check.sh) | M1: reconciles the layer `apps-monitoring`, waits for Prometheus, Alertmanager, operator and kube-state-metrics to be Ready, checks the volume, shows memory requests/limits. | Flux reconcile only |
| [`monitoring-openbao-metrics.sh`](monitoring-openbao-metrics.sh) | M2: rolls out the OpenBao metrics listener (restarts and unseals the pods one by one via `openbao-tls-rollout.sh`), reads the metrics over HTTPS verified with the demo CA, checks plain HTTP and Traefik give no metrics, shows Prometheus' scrape config. | Yes: OpenBao pod restarts |
| [`monitoring-cnpg-metrics.sh`](monitoring-cnpg-metrics.sh) | M2: applies the PostgreSQL PodMonitor, reads the primary's metrics (port 9187), shows the metrics the alerts use (backup timestamps, replication). | Flux reconcile only |
| [`monitoring-eso-metrics.sh`](monitoring-eso-metrics.sh) | M2: applies the ESO metrics TLS change (controller restarts once), reads the metrics over HTTPS verified with the demo CA, checks plain HTTP gives none, checks the scrape config and that the target is up. | Yes: ESO controller restart |
| [`monitoring-netpol-check.sh`](monitoring-netpol-check.sh) | M3: applies the `allow-prometheus-metrics` NetworkPolicies and probes ports 9101/9187/8080 with temporary busybox pods (open only from Prometheus' label in `monitoring`), then waits until every target is up. | Temporary probe pods (deleted) |

Proving an alert: `failure-f3-sealed.sh` takes `F3_WATCH_ROUNDS` (15 s rounds
before the unseal, default 8) and `F3_OUT` (evidence file); see
`docs/runbooks/monitoring.md`, section 5.
