# Scripts

Every script explains at the top what it does, step by step, with the real
commands. They print PASS / FAIL / INFO lines with UTC times and never print
keys or tokens. Scripts for daily use are listed in the README section
"Operations"; failure tests in `docs/runbooks/failure-tests.md`.

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
