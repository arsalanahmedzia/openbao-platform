# Time log

Time spent per task, estimated from the commit times: commits less than an hour
apart count as one work session, plus 30 minutes before the first commit of each
session, rounded to half hours. Planning, reading the task and the official docs,
and understanding each component left no commits; that time is an estimate in its
own row.

| Date | Phase | Task | Hours |
| --- | --- | --- | --- |
| 2026-10-22 to 2026-11-03 | Planning | Reading the task, planning the layers and the order, reading the official docs, understanding each component before building it | 6 |
| 2026-10-22 | Setup | Repository skeleton, Codespace environment, tool installation | 3.5 |
| 2026-10-25 | Storage | In-cluster S3 (SeaweedFS), encrypted S3 credentials, bucket Job, ADRs 0001/0002 | 2 |
| 2026-10-25 | Database | HA PostgreSQL (CloudNativePG), S3 backups, replication/failover/PITR tests, runbook, ADR 0003 | 2 |
| 2026-10-26 | OpenBao | OpenBao HA on PostgreSQL (Flux layer, SOPS DB password), init/unseal/configure scripts, HTTPS ingress, failover test, runbook, ADR 0004 | 1.5 |
| 2026-10-26 | External Secrets | TLS on the OpenBao listener, ClusterSecretStore, ExternalSecret pull + refresh test, PushSecret, policy fix (most specific path wins), least-privilege evidence, runbook, ADR 0005 | 1.5 |
| 2026-10-26 | Hardening | Backup schedule, GitHub token check, OpenBao audit device, root-token scripts, NetworkPolicies in 5 namespaces (enforcement tested), risk assessment | 3 |
| 2026-10-27 to 2026-10-28 | Failure tests | F1 worker node, F2 PostgreSQL primary, F3 sealed OpenBao, F4 PushSecret delete, F5 ESO restart, F6 point-in-time restore; pod-network repair after a Codespace restart; failure-test runbook and scripts | 2.5 |
| 2026-10-28 | Docs | README sections, risk assessment update | 1.5 |
| 2026-10-28 | Monitoring | kube-prometheus-stack layer; metrics from OpenBao (TLS listener 9101), PostgreSQL, ESO (TLS); NetworkPolicies for Prometheus; 8 alert rules (promtool-tested); check script; alert proven with an F3 re-run; runbook, ADR 0007, risk update | 3 |
| 2026-10-29 | Scripts | Scripts sorted into folders, one header format with a plain explanation, new PostgreSQL, S3 and Traefik checks, test gate shows why the monitoring check failed | 2 |
| 2026-10-29 | Docs | README overview, request/response tables, mermaid diagram, production readiness | 2.5 |
| 2026-11-03 | Docs | ADR 0006 (security hardening), README, operations, architecture and scripts README shortened | 1 |

**Total:** about 32 hours
