# ADR 0006: Security hardening

- Status: accepted
- Date: 2026-10-26
- Evidence: [`docs/evidence/06-hardening.txt`](../evidence/06-hardening.txt)
- Related: least-privilege OpenBao policies and TLS on the OpenBao listener
  were decided in [ADR 0005](0005-external-secrets-openbao.md); metrics
  access for Prometheus in [ADR 0007](0007-monitoring.md).

## Problem

After the platform worked, the risk assessment listed weaknesses that could be
fixed inside this cluster: backups that did not run, no audit trail in
OpenBao, a root token that never expires, an undocumented GitHub token, and
no network rules at all, so any pod could connect to OpenBao, PostgreSQL or
the backup storage. Each change had to be safe to roll back and must not
break the running platform.

## Options and choice

### Backup schedule (R06)

The daily base backup ran at 02:00 UTC, when the Codespace is usually
stopped, so it did not run.

- Options: keep 02:00 and rely on the missed slot running later; or move it
  to a time when the Codespace usually runs.
- Choice: 12:00 UTC (13:00 Berlin in winter, 14:00 in summer), in
  [`apps/database/backups.yaml`](../../apps/database/backups.yaml). A slot
  missed while the Codespace is stopped still runs once when the operator
  runs again.

### Prune protection (R07)

Flux deletes objects that disappear from Git (prune). The label
`kustomize.toolkit.fluxcd.io/prune: disabled` excludes an object from that.

- Options: put the label on the PostgreSQL Cluster and other stateful
  objects; or leave prune on.
- Choice: no prune protection (owner decision); R07 is accepted. Deleting
  a namespace still deletes everything in it, so protecting the Cluster object
  alone would not protect its data, and protected objects would have to be
  deleted by hand.

### GitHub token (R08)

- Choice: document which token is really stored in `FLUX_GITHUB_TOKEN`
  and add a checklist for the manual GitHub steps (branch protection, 2FA,
  revoking tokens and deploy keys at the end) in
  [`docs/environment.md`](../environment.md).
  `scripts/verify/github-access.sh` shows the token types, scopes and deploy
  keys without printing a token.

### OpenBao audit log (R11)

- Options: an audit device that writes to stdout (the pod log), or to a file
  on a volume.
- Choice: stdout, declared in the server config in
  [`apps/openbao/helmrelease.yaml`](../../apps/openbao/helmrelease.yaml).
  OpenBao 2.7.1 does not allow creating audit devices through the API by
  default, so the config file is the way to declare it. Every request and
  response is one JSON line; secret values and tokens are written as
  HMAC-SHA256 hashes. The evidence shows one read of `secret/demo/hello` with
  the token and the value as hashes, and the plain value 0 times in the log.

### Root token (R01)

The root token can do everything and was still needed for configuration.

- Choice: do not revoke it yet. `scripts/openbao/openbao-revoke-root.sh`
  revokes it and checks that it is refused; `scripts/openbao/openbao-generate-root.sh`
  creates a new one from 3 key shares when needed. Both are prepared, not
  run; generate-root is untested.

### Network rules (R10)

First, a test had to show that this cluster enforces NetworkPolicies at all:
kind v0.33.0 uses kindnet with kube-network-policies, and
`scripts/hardening/netpol-enforcement-test.sh` proved that a deny-all rule
blocks a connection and an allow rule opens it again.

- Options: no rules; the OpenBao chart's own policy (`server.networkPolicy`,
  which opens 8200 and 8201 to every namespace); or default-deny ingress per
  namespace with explicit allow rules.
- Choice: default-deny ingress, then allow rules, one namespace at a time:
  `storage`, `databases`, `openbao`, `external-secrets`, `eso-demo`. Ports and
  labels come from the repo and the charts, not from guesses. Each namespace
  has a test script in `scripts/hardening/` that proves the allowed paths work
  and the blocked paths fail. The rules sit next to what they protect
  (`networkpolicy.yaml` in each folder; see
  [`docs/architecture.md`](../architecture.md)).
- Egress rules (stretch goal, `openbao` only): not built, owner decision.

## Not done

Paused and left as open risks in the
[risk assessment](../risk-assessment.md): Pod Security Standards, narrower
token rights for ESO (R09), a narrower `eso-read` policy (R20), PostgreSQL
`sslmode=verify-full` from OpenBao (R15), and egress rules (R10).

## Trade-offs

- The audit device is a dependency: if every audit device fails to write,
  OpenBao refuses requests. With stdout this is unlikely, but the audit log
  lives only as long as the pod log.
- The API server reaches the PostgreSQL instance manager (port 8000) and the
  ESO webhook (port 10250) from the kind node network. That rule allows all of
  `172.16.0.0/12`, because the kind network range changes when the cluster is
  rebuilt (it was 172.18, then 172.19). It is wider than one address.
- Port 8000 allows every CloudNativePG instance (`cnpg.io/podRole: instance`),
  not only `pg-openbao`, so a restore cluster can be managed (found in
  failure test F6).
- Kubelet health probes are not affected: kube-network-policies always accepts
  traffic generated by root on the node.
- No egress rules: a compromised pod can still connect out.
- Without prune protection, removing a layer from Git deletes its objects,
  including the PostgreSQL Cluster (R07).
