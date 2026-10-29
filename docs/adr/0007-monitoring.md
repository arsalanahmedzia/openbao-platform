# ADR 0007: Monitoring and alerting with kube-prometheus-stack

- Status: accepted
- Date: 2026-10-28
- Number: 0006 is taken by the security-hardening decisions (referenced in the
  NetworkPolicy files; the document itself is not written yet).

## Problem

Nothing watched the platform (risk R11). The failure tests showed failures
that nobody would notice: a sealed OpenBao (F3: the store even stayed
"Valid"), a lost node (F1), a late backup (R06). We need metrics from OpenBao,
PostgreSQL and External Secrets, alerts for the important failures, and a way
to check them, all from Git through Flux, in a Codespace with 16 GB.

Questions: which stack, where the monitoring objects live, how Prometheus
reaches the metrics endpoints (default-deny NetworkPolicies), whether the
metrics travel encrypted, and which alerts.

## Options

Stack
1. kube-prometheus-stack (chart 92.3.1): Prometheus Operator with the
   resource types `PodMonitor`/`ServiceMonitor`/`PrometheusRule`, Prometheus,
   Alertmanager, kube-state-metrics.
2. The plain `prometheus` chart (29.39.0): no operator, so no monitor or rule
   objects; every scrape and alert is hand-written Prometheus config.
3. VictoriaMetrics: less memory, but its own resource types (`VMServiceScrape`,
   `VMRule`), a second set of concepts. Not worth it for a few alerts.

Where the monitors and rules live
1. All in `apps/monitoring/`, pointing at the other namespaces with
   `namespaceSelector`.
2. Next to each component (e.g. a PodMonitor in `apps/database/`): then those
   layers depend on the operator's CRDs and fail on a fresh cluster until
   monitoring is installed.

Metrics transport
1. Plain HTTP, protected only by a NetworkPolicy.
2. TLS where the component supports it, with a certificate Prometheus
   verifies (demo CA plus server name; never `insecureSkipVerify`).

## Choice

- kube-prometheus-stack 92.3.1 (Prometheus v3.15.0, Alertmanager v0.34.1,
  operator v0.94.1, kube-state-metrics 2.20.0), Flux layer `apps-monitoring`
  (depends on `infra-controllers` and `infra-configs`). Off: Grafana,
  node-exporter, the chart's default rules, control-plane and kubelet/cAdvisor
  scrapes, the admission webhook (and with it the operator's TLS, which only
  serves that webhook). Prometheus 1 replica, scrape every 30 s, retention
  2 days, `retentionSize: 1GB`, 2 Gi volume. Memory requests/limits:
  Prometheus 320 Mi / 1 Gi, Alertmanager 48 Mi / 160 Mi, operator and
  kube-state-metrics 64 Mi / 256 Mi each (about 500 Mi / 1.7 Gi in total).
  `crds: CreateReplace` so chart upgrades update the CRDs;
  `*SelectorNilUsesHelmValues: false` so Prometheus picks up our monitors
  without Helm labels.
- All monitors and the PrometheusRule in `apps/monitoring/`. PodMonitors,
  not ServiceMonitors: no component needs an extra metrics Service.
- NetworkPolicies: one new `allow-prometheus-metrics` per namespace
  (openbao 9101, databases 9187, external-secrets 8080), only from the pod
  with label `app.kubernetes.io/name=prometheus` in namespace `monitoring`.
  They live in each namespace's own policy file, so each file stays the full
  list of what may enter that namespace, and no layer order problem arises on
  a fresh cluster. Existing policies are unchanged.
- OpenBao: a second listener on port 9101 with `metrics_only` and
  `unauthenticated_metrics_access` (no token in Prometheus), HTTPS with the
  same demo-CA certificate as port 8200. Metrics are switched off on 8200
  (`disallow_metrics`), so they are not reachable through Traefik. Not 8202:
  the chart already declares that port. Prometheus verifies the certificate
  with the demo CA and the name `openbao.openbao.svc` (all pods share one
  certificate). A PodMonitor can only read Secrets in its own namespace, so
  the CA comes from a small cert-manager Certificate `monitoring/prometheus-client`
  whose Secret contains `ca.crt`; the CA is never copied into Git.
- External Secrets: controller metrics over HTTPS (`metrics.listen.secure`)
  with a demo-CA certificate from `infrastructure/configs/`, mounted at
  `/etc/tls`. `certFile`/`keyFile` must be file names (`tls.crt`): the chart
  default (`/etc/tls/tls.crt`) is joined with `certDir` by controller-runtime,
  finds no file and silently falls back to a self-signed `localhost`
  certificate. `install.disableWait` avoids a deadlock on a fresh bootstrap
  (the pod needs a Secret that only the next layer creates). PodMonitor with
  `honorLabels: true`, so alerts name the ExternalSecret's namespace, not the
  controller's.
- CloudNativePG: plain HTTP on 9187 + NetworkPolicy (known gap, R30).
  CloudNativePG can serve metrics over TLS (`spec.monitoring.tls.enabled`),
  but only with PostgreSQL's own server certificate, signed by the operator's
  CA in Secret `databases/pg-openbao-ca`. That Secret also holds `ca.key`; a
  PodMonitor in `monitoring` cannot reference it, and moving the PodMonitor to
  `databases` would let the Prometheus Operator read a Secret with a CA key,
  which we do not want. The change would also roll all 3 instances (primary
  recreated without switchover). Production fix: give PostgreSQL a server
  certificate from cert-manager/demo CA (`spec.certificates.serverTLSSecret`,
  `serverCASecret`), then enable metrics TLS (switchover first); the same
  certificate would also allow OpenBao `sslmode=verify-full` (R15).
- Flux metrics: not collected. Flux 2.x exposes the ready state of
  Kustomizations/HelmReleases only through a kube-state-metrics custom
  resource configuration; `scripts/checks/test-gate.sh` already checks Flux.
- Alerts (`apps/monitoring/prometheusrule.yaml`, every metric name checked
  in the real exporter output or the pinned version's docs, logic unit-tested
  with `promtool test rules`):

  | Alert | Fires when | for |
  | --- | --- | --- |
  | OpenBaoSealed | `vault_core_unsealed` is 0 or the pod is not Ready (readiness = `bao status`), per pod | 2m |
  | ExternalSecretNotReady / PushSecretNotReady | Ready condition False | 5m |
  | ClusterSecretStoreNotReady | Ready condition False ("Valid" is that condition's reason) | 5m |
  | ExternalSecretsControllerDown | controller not scraped (the ESO alerts above need its metrics) | 5m |
  | PostgresNotHealthy | fewer than 3 instances up, or no primary | 5m |
  | BackupFailedOrTooOld | last good backup older than 26 h (daily at 12:00), a newer failed backup, or no metric | 15m |
  | NodeNotReady | node Ready condition not true | 2m |

  No Alertmanager receiver: alerts are visible in Prometheus and Alertmanager
  and with `scripts/monitoring/monitoring-check.sh`, nothing is sent.

## Trade-offs

- One Prometheus, one Alertmanager, no receiver: if the node with the
  monitoring pods fails (all 4 ran on worker3), monitoring stops with it, and
  nobody is notified of anything. Production: 2 replicas, a receiver
  (mail/chat/on-call), and a watchdog alert checked from outside.
- Two signals in OpenBaoSealed: a pod that is not Ready for another reason
  (e.g. crash loop) also raises "sealed (or not ready)". Accepted: both need
  the same first look.
- 2 days of retention: enough for alerts, not for trends.
- The OpenBao metrics listener needs no token. Acceptable because it serves
  only metrics (no secrets), is TLS-only and only Prometheus may connect.
- CloudNativePG metrics unencrypted on the pod network (R30), see above.
- Metrics port and certificate checks are proven (docs/evidence/08-monitoring.txt);
  a fresh `flux bootstrap` with the ESO TLS change was not tested.
