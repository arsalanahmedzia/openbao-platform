# Time log

Time spent per task, recorded as the work happened.

| Date | Phase | Task | Hours |
| --- | --- | --- | --- |
| 2026-10-22 | Setup | Repository skeleton, AWS/EC2 environment, tool installation | |
| 2026-10-25 | Storage | In-cluster S3 (SeaweedFS), encrypted S3 credentials, bucket Job, ADRs 0001/0002 | |
| 2026-10-25 | Database | HA PostgreSQL (CloudNativePG), S3 backups, replication/failover/PITR tests, runbook, ADR 0003 | |
| 2026-10-26 | OpenBao | OpenBao HA on PostgreSQL (Flux layer, SOPS DB password), init/unseal/configure scripts, HTTPS ingress, failover test, runbook, ADR 0004 | |
| 2026-10-26 | External Secrets | TLS on the OpenBao listener, ClusterSecretStore, ExternalSecret pull + refresh test, PushSecret, policy fix (most specific path wins), least-privilege evidence, runbook, ADR 0005 | |
| 2026-10-26 | Hardening | Backup schedule, GitHub token check, OpenBao audit device, root-token scripts, NetworkPolicies in 5 namespaces (enforcement tested), risk assessment | |
| 2026-10-27 to 2026-10-28 | Failure tests | F1 worker node, F2 PostgreSQL primary, F3 sealed OpenBao, F4 PushSecret delete, F5 ESO restart, F6 point-in-time restore; pod-network repair after a Codespace restart; failure-test runbook and scripts | |
| 2026-10-28 | Docs | README sections, risk assessment update | |
| 2026-10-28 | Monitoring | kube-prometheus-stack layer; metrics from OpenBao (TLS listener 9101), PostgreSQL, ESO (TLS); NetworkPolicies for Prometheus; 8 alert rules (promtool-tested); check script; alert proven with an F3 re-run; runbook, ADR 0007, risk update | |

**Total:** _TODO_
