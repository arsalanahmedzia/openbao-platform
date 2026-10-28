# Operations: monitoring, alerting, troubleshooting

How to keep the platform running day to day. Words are explained in the
[glossary](glossary.md).

## What it is

This file lists the scripts you use every day, the one known problem after a
Codespace restart, and the alerts that tell you when something breaks. It is
the starting point when something does not work.

## Why we need it

OpenBao starts sealed after every restart, and the Codespace can break the pod
network when it restarts. Without these checks and alerts a broken part could
stay unnoticed until a secret is missing.

## Scripts for daily use

| Script | When |
| --- | --- |
| [`scripts/resume.sh`](../scripts/resume.sh) | After a Codespace restart: starts the nodes, fixes the network, checks the pod network |
| [`scripts/openbao-unseal.sh`](../scripts/openbao-unseal.sh) | After every OpenBao pod restart (pods start sealed) |
| [`scripts/test-gate.sh`](../scripts/test-gate.sh) | Is everything OK? Read-only check of Flux, OpenBao, PostgreSQL, External Secrets and monitoring |
| [`scripts/monitoring-check.sh`](../scripts/monitoring-check.sh) | Read-only: all scrape targets up, alert rules loaded, which alerts are pending or firing |
| [`scripts/eso-debug.sh`](../scripts/eso-debug.sh) | Why is an ExternalSecret or PushSecret not Ready? |
| `scripts/failure-f1-worker.sh` … `scripts/failure-f6-restore.sh` | One failure test each; asks before it breaks anything and puts everything back at the end |

Outputs of all tests are in [`evidence/`](evidence/). Runbooks:
[`runbooks/`](runbooks/). All scripts: [`scripts/README.md`](../scripts/README.md).

## Step by step: after a Codespace restart

1. Run `bash scripts/resume.sh`. It starts the kind node containers again,
   re-adds the firewall rule that a restart removes (see
   [`environment.md`](environment.md)), checks DNS in the nodes and waits until
   the nodes are Ready, because a Codespace restart stops or breaks all of
   these. It also checks the pod network (next section).
2. If it reports the pod network problem, it runs
   `scripts/kind-fix-pod-network.sh` for you (it asks first). That script
   restarts kindnet (kind's pod network) and recreates the affected pods.
3. Run `bash scripts/openbao-unseal.sh`. Every OpenBao pod that restarted is
   sealed (it cannot read its data); the script gives each pod 3 of its 5 key
   shares. See the [unseal runbook](runbooks/openbao-init-unseal.md).
4. Run `bash scripts/test-gate.sh`. It checks Flux, OpenBao, PostgreSQL,
   External Secrets and monitoring without changing anything, and ends with
   `GATE PASSED` or a list of failures.

## Known problem after a Codespace restart

Docker can give the kind node containers different IP addresses after a
Codespace restart. kindnet then hands out pod IPs from another node's range,
DNS fails, and OpenBao crash-loops because it cannot reach PostgreSQL (risk
R27). `scripts/resume.sh` checks this and runs
[`scripts/kind-fix-pod-network.sh`](../scripts/kind-fix-pod-network.sh), which
restarts kindnet and recreates the affected pods (it asks first).

## Monitoring and alerting

What it is: Prometheus (namespace `monitoring`, layer `apps-monitoring`)
collects numbers from the platform every 30 s and checks 8 alert rules.
It scrapes (reads the numbers of) OpenBao (HTTPS, port 9101), the 3
PostgreSQL instances (port 9187) and the External Secrets controller (HTTPS,
port 8080), plus kube-state-metrics for pod and node state.

Why we need it: the failure tests showed problems nobody would notice, for
example a sealed OpenBao (F3) or a lost node (F1). The alerts name them.

Design: [ADR 0007](adr/0007-monitoring.md). Full runbook with what to do for
each alert: [`runbooks/monitoring.md`](runbooks/monitoring.md).

The alerts:

| Alert | Fires when |
| --- | --- |
| OpenBaoSealed | an OpenBao pod is sealed or not ready for 2 min |
| ExternalSecretNotReady / PushSecretNotReady | a sync has failed for 5 min |
| ClusterSecretStoreNotReady | the store is not Valid for 5 min |
| ExternalSecretsControllerDown | the ESO controller cannot be scraped for 5 min |
| PostgresNotHealthy | fewer than 3 PostgreSQL instances up, or no primary, for 5 min |
| BackupFailedOrTooOld | no successful backup for 26 h, or the last backup failed |
| NodeNotReady | a node is not Ready for 2 min |

Proof: on 2026-10-28, with OpenBao sealed (re-run of failure test F3),
OpenBaoSealed fired after 2 min 22 s and reached Alertmanager
([`evidence/08-monitoring.txt`](evidence/08-monitoring.txt)).

No receiver is configured: alerts are visible in the UIs (port-forward, see
the [monitoring runbook](runbooks/monitoring.md)) and in
`scripts/monitoring-check.sh`; nothing is sent. The OpenBao audit log goes to
the pod log.

Example: a smoke detector without a phone line. It beeps in the flat when
there is smoke, but nobody outside hears it. Our alerts work the same way:
someone has to look at them (risk R31).

## What can go wrong

- `test-gate.sh` fails on "3 OpenBao pods Ready": the pods are sealed after a
  restart. Fix: `bash scripts/openbao-unseal.sh`.
- OpenBao pods crash-loop and logs show they cannot reach PostgreSQL after a
  Codespace restart: the pod network problem above (R27). Fix:
  `bash scripts/resume.sh`.
- `test-gate.sh` fails on the monitoring check: an alert is firing or a
  target is down. Run `bash scripts/monitoring-check.sh` to see which, then
  look up the alert in the [monitoring runbook](runbooks/monitoring.md).
- An ExternalSecret is not Ready: `bash scripts/eso-debug.sh` shows the
  reason (often OpenBao sealed or unreachable).
