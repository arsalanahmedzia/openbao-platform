# Task brief: security hardening stage

Read CLAUDE.md and docs/risk-assessment.md first. All rules in CLAUDE.md still apply.
This brief turns the risk assessment into work: what can be built and tested in
this cluster is built; the rest stays documented as a production gap.

## Rules (same as the OpenBao and External Secrets stages)

- You write files and scripts and commit them. **I run every command that touches the cluster.**
  You do not run kubectl, flux, bao or bootstrap yourself.
- One short script per step, clear name, comments, so I run `bash scripts/<name>.sh`.
- Before each step: one or two plain sentences on what it does and why. After each step:
  which output means it worked. Then wait for me.
- Everything in the cluster comes from Git through Flux. No lasting `kubectl apply` by hand.
- No secret values in chat, evidence, commits or logs. Pin versions. Small commits, plain
  messages, no `Co-Authored-By` or generated-by lines.
- If you must choose between options, ask me and recommend one.
- **Test gate after every item:** I run `scripts/eso-evidence.sh`, the OpenBao check scripts and
  the PostgreSQL status check. If something that worked before breaks, we revert that commit
  first and debug afterwards. Never stack a second change on a broken one.
- **Time box:** if an item does not work within about 30 minutes, stop, revert it, and record it
  in the risk assessment as a known gap with the reason. A documented gap is fine. A broken
  platform is not.
- The failure-test stage (docker stop worker, PostgreSQL failover, sealed OpenBao, PushSecret
  deletion, restore) is a requirement of the task and comes after this stage. Do not shorten it.

## Phase A: safe changes (cannot lock me out of the cluster)

A1. **Backup schedule (R06).** Move the ScheduledBackup to a time when the Codespace is usually
    running (ask me for a time, recommend one in Berlin time and convert to UTC). Script: show the
    schedule and the age of the last successful backup. Take a manual backup to prove it works.
A2. **Prune protection (R07).** Add `kustomize.toolkit.fluxcd.io/prune: disabled` to the
    PostgreSQL Cluster and to other stateful objects where it makes sense (ask me which). Explain
    in the ADR what this does and the cost: such objects must then be deleted by hand.
A3. **Token documentation (R08).** Correct docs/environment.md so it says which token is really
    stored in FLUX_GITHUB_TOKEN (the `gh` login token with repo and codespace:secrets scopes, saved
    with `gh auth token | gh secret set`). Add a checklist for me with the manual GitHub steps:
    branch protection on `main`, 2FA, revoke tokens and stale deploy keys at the end.
A4. **OpenBao audit device (R11).** Enable an audit device. Ask me which target: stdout (goes to
    the pod log, simplest) or a file on a volume. Explain the risk: if every audit device fails,
    OpenBao refuses requests. Script: enable it (idempotent, uses the root token from the
    Codespaces secret, never printed), make one read as the ESO login, and show the audit entry.
    Show that values are hashed in the log, not plain.
A5. **Root token.** Do NOT revoke it yet; I still need it for the later steps. Prepare
    `scripts/openbao-revoke-root.sh` and make sure the runbook describes how to get a new root
    token from 3 key shares (`generate-root`). Mark the generate-root steps as untested unless
    we test them.

## Phase B: riskier changes (tomorrow morning, one at a time, test gate after each)

B1. **Do NetworkPolicies work here? (first, before any real policy).** In a scratch namespace:
    two pods, a deny-all ingress policy, show that the connection really fails. If the CNI does
    not enforce policies, stop and tell me; then the options are another CNI (needs a rebuild)
    or documenting it as a gap.
B2. **Default-deny ingress, then explicit allows,** one namespace at a time, in this order:
    `storage` (only from `databases`, port 8333), `databases` (only from `openbao`, the
    CloudNativePG operator, the Barman plugin and between the PostgreSQL pods themselves),
    `openbao` (only from Traefik, `external-secrets` and the OpenBao pods themselves for HA
    forwarding), `external-secrets`, `eso-demo`. Read the real ports and labels from the repo; do not
    guess. Egress default-deny is a stretch goal: only attempt it for `openbao` and only after
    everything else works (DNS and the Kubernetes API must stay reachable).
    Scripts: one connectivity test per policy that proves allowed paths work and blocked paths fail.
B3. **Pod Security Standards.** Label namespaces with `pod-security.kubernetes.io/warn` and
    `audit` first. Show which workloads would violate `baseline` / `restricted`. Enforce only
    where nothing violates, fix cheap violations (securityContext), and document the rest
    (e.g. SeaweedFS running as root) as accepted with a reason.
B4. **ESO token rights (R09).** Set `rbac.serviceAccountTokenCreate: false` (check the exact
    chart value for the pinned version, do not guess) and allow token creation only for the
    `external-secrets` service account (Role with `resourceNames`). Retest store, pull, refresh,
    push.
B5. **Narrow `eso-read` (R20).** Limit it to the paths ESO really needs (`secret/data/demo/*` and
    matching metadata), update the policy file, rerun the policy script and the evidence scripts.
B6. **PostgreSQL connection from OpenBao (R15).** Move from `sslmode=require` to `verify-full`
    with the CloudNativePG CA mounted into OpenBao. Optional: do it only if B1 to B5 are done
    and stable. OpenBao pods use OnDelete, so rolling them needs the rollout script and unseal.

## Not built here, documented as production gaps

Auto-unseal with a KMS/HSM, off-cluster backups, encryption of Kubernetes Secrets at rest
(needs a cluster rebuild with an EncryptionConfiguration), image digests and signature
verification, trust-manager for publishing only the CA, monitoring and alerting, Terraform for
the OpenBao configuration. Make sure each appears in docs/risk-assessment.md with a one-line
production fix.

## Deliverables

- Scripts for every item above, committed.
- `docs/adr/0006-security-hardening.md`: what was built, the alternatives, the trade-offs and
  the accepted gaps.
- `docs/risk-assessment.md` updated: for each risk, status (mitigated / accepted / open), the
  new likelihood or impact, and the evidence file.
- `docs/evidence/06-hardening.txt` with the outputs of the tests, scanned for tokens and keys.
- README "security" section and a runbook note for NetworkPolicy debugging.

## Final summary (at the end)

Plain English, no analogies: what was built, five sentences I must be able to explain with
their reasons, every place where you were unsure or did not verify, and which risks changed
status.
