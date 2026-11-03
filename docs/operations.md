# Operations

How to keep the platform running day to day: the scripts, the one known
problem after a Codespace restart, and the alerts. Words are explained in the
[glossary](glossary.md).

## Scripts for daily use

| Script | When |
| --- | --- |
| [`scripts/after-restart/resume.sh`](../scripts/after-restart/resume.sh) | After a Codespace restart: starts the nodes, fixes the network, checks the pod network |
| [`scripts/after-restart/openbao-unseal.sh`](../scripts/after-restart/openbao-unseal.sh) | After every OpenBao pod restart (pods start sealed) |
| [`scripts/verify/test-gate.sh`](../scripts/verify/test-gate.sh) | Is everything OK? Read-only check of Flux, OpenBao, PostgreSQL, External Secrets and monitoring |
| [`scripts/monitoring/monitoring-check.sh`](../scripts/monitoring/monitoring-check.sh) | Read-only: all scrape targets up, alert rules loaded, which alerts are pending or firing |
| [`scripts/external-secrets/eso-debug.sh`](../scripts/external-secrets/eso-debug.sh) | Why is an ExternalSecret or PushSecret not Ready? |
| `scripts/failure-tests/failure-f1-worker.sh` … `scripts/failure-tests/failure-f6-restore.sh` | One failure test each; asks before it breaks anything and puts everything back at the end |

Outputs of all tests are in [`evidence/`](evidence/). Runbooks:
[`runbooks/`](runbooks/). All scripts: [`scripts/README.md`](../scripts/README.md).

## After a Codespace restart

1. Run `bash scripts/after-restart/resume.sh`. It starts the kind node containers again,
   re-adds the firewall rule that a restart removes (see
   [`environment.md`](environment.md)), checks DNS in the nodes, waits until
   the nodes are Ready and checks the pod network.
2. Run `bash scripts/after-restart/openbao-unseal.sh`. Every OpenBao pod that restarted is
   sealed (it cannot read its data); the script gives each pod 3 of its 5 key
   shares. See the [unseal runbook](runbooks/openbao-init-unseal.md).
3. Run `bash scripts/verify/test-gate.sh`. It checks Flux, OpenBao, PostgreSQL,
   External Secrets and monitoring without changing anything, and ends with
   `GATE PASSED` or a list of failures.

## Known problem after a Codespace restart

Docker can give the kind node containers different IP addresses after a
Codespace restart. kindnet (kind's pod network) then hands out pod IPs from
another node's range, DNS fails, and OpenBao crash-loops because it cannot
reach PostgreSQL (risk R27). `scripts/after-restart/resume.sh` checks this and runs
[`scripts/after-restart/kind-fix-pod-network.sh`](../scripts/after-restart/kind-fix-pod-network.sh), which
restarts kindnet and recreates the affected pods (it asks first).

## Monitoring and alerting

Prometheus reads the numbers of OpenBao, PostgreSQL, ESO and kube-state-metrics
every 30 s and checks 8 alert rules. What each alert means and what to do:
[`runbooks/monitoring.md`](runbooks/monitoring.md). Design:
[ADR 0007](adr/0007-monitoring.md).

On 2026-10-28, with OpenBao sealed (re-run of failure test F3), OpenBaoSealed
fired after 2 min 22 s and reached Alertmanager
([`evidence/08-monitoring.txt`](evidence/08-monitoring.txt)).

No receiver is configured, so nothing is sent: someone has to look at the
alerts in the UIs (port-forward, see the [monitoring runbook](runbooks/monitoring.md))
or with `scripts/monitoring/monitoring-check.sh` (risk R31). The OpenBao audit log goes
to the pod log.

## Common failures

- `test-gate.sh` fails on "3 OpenBao pods Ready": the pods are sealed after a
  restart. Fix: `bash scripts/after-restart/openbao-unseal.sh`.
- `test-gate.sh` fails on the monitoring check: an alert is firing or a
  target is down. `bash scripts/monitoring/monitoring-check.sh` shows which; the
  [monitoring runbook](runbooks/monitoring.md) says what to do.
- An ExternalSecret is not Ready: `bash scripts/external-secrets/eso-debug.sh` shows the
  reason (often OpenBao sealed or unreachable).
