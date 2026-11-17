# Task brief: monitoring and alerting stage

Read CLAUDE.md, docs/risk-assessment.md, docs/runbooks/ and docs/adr/ first. All rules in CLAUDE.md still apply.
The platform is built, hardened and failure-tested. This stage adds a small monitoring and alerting setup.
It is a bonus stage: the failure-test docs, risk assessment and time log have priority.

## Rules (same as the earlier stages)

- **One short script per check or action**, clear name, comments at the top, so I only run
  `bash scripts/<name>.sh`. Long commands go inside the script, not into my terminal.
  You write and commit the scripts. **I run every command that touches the cluster.** You do not
  run kubectl, flux, bao, docker or bootstrap yourself.
- Scripts print plain `PASS` / `FAIL` / `INFO` lines. Never print a token, key share or secret value.
- At the top of each script, comments in plain English: what it does, in numbered steps, and the
  real commands it runs.
- Before each step: two plain sentences (what we change, what we expect). After each step: which output
  means it worked. Then wait for me.
- **Test gate:** run `bash scripts/test-gate.sh` before the first step and after every step that changes the
  cluster. If it does not say `GATE PASSED`, we fix that first.
- **Time box: 90 minutes in total.** If a part is stuck, stop, put the cluster back, record it as a known
  gap with the reason in docs/risk-assessment.md, and go on.
- If a result is different from what you expected, say so. Do not change the expectation afterwards.
- If you are unsure about a command or a metric name, check the docs or the real output and say that you are unsure.
- Small commits, plain messages, one step per commit. Do not push. Do not touch CLAUDE.md.
- Explanations in docs: short sentences, plain English, no analogies, explain every term at first use.

## Limits of the environment

Codespace 4 cores, 16 GB RAM (about 9 GB free), about 13 GB disk free, kind with 4 nodes.
Keep it small: Prometheus (1 replica) + Alertmanager + kube-state-metrics + the operator. No Grafana.
Short retention (2 days). Set resource requests and limits. Pin exact chart and image versions (ADR 0001).
Tell me which chart you choose (kube-prometheus-stack with most parts disabled, or something smaller),
why, and how much memory it needs, before you write the manifests.

## Start state (I do this, not you)

`bash scripts/resume.sh`, `bash scripts/openbao-unseal.sh`, `bash scripts/test-gate.sh` must be green.

## Steps, in this order

**M1. Flux layer.** New layer `apps-monitoring` in the same style as the other layers (dependsOn the layers it needs,
wait: true), manifests in `apps/monitoring/`. Expected: Prometheus and Alertmanager pods Running.

**M2. Metrics sources, one by one.** For each, say what must change and whether pods restart:
- OpenBao: telemetry on the listener. Check the OpenBao docs for unauthenticated metrics access and tell me
  if it is safe here. A config change restarts the pods, they come back sealed, and I run
  `bash scripts/openbao-unseal.sh`. Tell me before applying.
- CloudNativePG: PodMonitor for `pg-openbao`.
- External Secrets Operator: metrics service and ServiceMonitor.
- Flux controllers: only if cheap.

**M3. NetworkPolicies.** Default-deny ingress exists. Add the minimum allow rules so Prometheus can scrape each
target. List every new rule and why. Show me before applying anything that changes an existing policy.

**M4. Alert rules (PrometheusRule).** Plain names and a short description inside each alert:
- OpenBaoSealed: a pod is sealed for more than 2 minutes
- ExternalSecretNotReady / ClusterSecretStore not Valid
- PostgresNotHealthy: fewer than 3 instances or no primary
- BackupFailedOrTooOld: no successful backup for 26 hours
- NodeNotReady
Verify each metric name in the real exporter output or the docs. If you cannot verify one, say so.

**M5. Check script.** `scripts/monitoring-check.sh` (read-only): lists targets up/down and active alerts through
a port-forward, prints PASS/FAIL. Add it to `scripts/test-gate.sh` only if it is stable.

**M6. Prove it.** Tell me which existing failure script to re-run (for example the sealed test) so that an alert
fires, and what to look for. Evidence into `docs/evidence/08-monitoring.txt`, scanned for tokens and keys.

## Deliverables

- Manifests in `apps/monitoring/` and the Flux layer.
- Scripts: `monitoring-check.sh` (and others only if needed). Entry in scripts/README.md.
- `docs/runbooks/monitoring.md`: what is watched, how to open the UI, what each alert means, what to do.
- An ADR (next free number): the choice and the rejected alternatives.
- README "Operations" section updated. `docs/risk-assessment.md`: which risks are now detected, new findings.
- `docs/time-log.md`: one entry.

## Final summary (at the end)

Plain English, no analogies:
- what was built and what each alert watches
- memory and disk before and after (tell me which commands to run, I paste the output)
- every place where you were unsure or did not verify something
- every result that was different from the expectation
- what is left for cleanup