# Task brief: workload that consumes the synced secret

Read CLAUDE.md first. Everything in CLAUDE.md still applies. This brief adds the rules for this task.

## Goal

The challenge asks for "evidence of successful secret synchronization from OpenBao to Kubernetes workloads, e.g. with an example deployment". Today the Secret `eso-demo/hello-from-openbao` exists, but no pod uses it. Add one small example workload that reads it, and prove that a change in OpenBao reaches the running pod.

Chain to prove: `secret/demo/hello` (OpenBao) -> ExternalSecret `hello` (ESO) -> Secret `hello-from-openbao` -> file inside a running pod.

## What already exists (verify in the repo, do not assume)

- `apps/external-secrets/` has the namespace `eso-demo`, the ClusterSecretStore `openbao`, the ExternalSecret `hello` (refresh 30 s), the PushSecret and a default-deny ingress NetworkPolicy. It is applied by the Flux layer `apps-external-secrets`.
- `scripts/external-secrets/eso-refresh-test.sh` changes the value as the separate demo writer (role `demo-writer`) and restores it.
- `scripts/hardening/netpol-test-eso-demo.sh` already uses the pinned image `busybox:1.37.0`.
- Docs that say "no pods": `apps/external-secrets/networkpolicy.yaml`, `docs/architecture.md` (about line 246), header of `scripts/hardening/netpol-test-eso-demo.sh`.

## Rules for this task

- You write files and scripts and commit them. **I run every command that touches the cluster.** You do not run kubectl, flux, bao or bootstrap yourself.
- One short script per step, with a clear name and the same header style as the other scripts (what it does, run it, changes the cluster, what you should see, if it fails, needs).
- Before each step: say in one or two plain sentences what it does and why. After each step: say which output means it worked. Then wait for me.
- No secret values in chat, evidence, commits or logs. The demo value `hello-from-openbao` is not secret and may be shown. Never print tokens.
- Everything in the cluster comes from Git through Flux. No lasting `kubectl apply` by hand.
- Pin versions (image tag, no `latest`). Commit small, one concern per commit, plain messages.
- Plain explanations, no analogies.

## Decisions (already made, change only if you find a reason)

1. **Mount as a file, not an environment variable.** The kubelet updates mounted Secret files; environment variables keep the old value until the pod restarts. No `subPath`, because a subPath mount is never updated.
2. **Image:** `busybox:1.37.0` (already used in the repo).
3. **The pod logs the value only when it changes.** Acceptable only because it is a demo value; say so in a comment.
4. **No new NetworkPolicy rule.** The pod only reads a file and needs no incoming traffic. Keep default-deny.
5. **Hardening for this pod:** non-root, read-only root filesystem, all capabilities dropped, no privilege escalation, seccomp `RuntimeDefault`, no service account token mounted, small resource requests and a memory limit.

If you disagree with one of these, ask me with a question and say which option you recommend.

## Steps

1. **Inspect (read-only).** Read `apps/external-secrets/`, the Flux layer `apps-external-secrets` in `clusters/demo/apps.yaml`, and the scripts above. Report anything that conflicts with the decisions (for example Pod Security labels on the namespace).
2. **Deployment.** Add `apps/external-secrets/deployment-hello-consumer.yaml` (Deployment `hello-consumer`, 1 replica, label `app.kubernetes.io/name: hello-consumer`) and list it in `apps/external-secrets/kustomization.yaml`. Add a readiness probe on the mounted file.
3. **Comments.** Update the "no pods" comment in `networkpolicy.yaml`, and the two other places listed above.
4. **Check script.** Add `scripts/external-secrets/eso-consume-check.sh`: apply Git through Flux, wait for the Deployment, show the volume and the user id, read the file in the pod, change the value in OpenBao as `demo-writer`, wait (max 5 min) until the **file in the pod** shows it, restore the value, wait again, print the pod log. The cleanup must restore the value and revoke the token also when the script fails. Tokens go to the pod through stdin.
5. **Run order for me:** `git push`, then `bash scripts/external-secrets/eso-consume-check.sh | tee docs/evidence/05b-workload-consumes-secret.txt`, then `bash scripts/verify/test-gate.sh`, then `bash scripts/hardening/netpol-test-eso-demo.sh`.
6. **Evidence check.** Scan `docs/evidence/05b-workload-consumes-secret.txt` for tokens (same grep as `eso-evidence.sh`) before committing.
7. **Docs.** Add a row to the requirements table in the README: "Workload consumes the synced secret" with the file and the evidence file. Add a short note to ADR 0005 (why a file mount, not an environment variable). Add a time log entry. Update `docs/runbooks/external-secrets.md` with one line: how to check the consumer (`kubectl -n eso-demo logs deploy/hello-consumer`) and that mounted files update 1 to 2 minutes after the Secret.

## Acceptance criteria

- The pod `hello-consumer` is Ready and runs as non-root.
- The file in the pod shows `hello-from-openbao`, then the changed value, then `hello-from-openbao` again; the pod log has one line per change.
- `apps-external-secrets` and all other Flux layers are `True`; `test-gate.sh` and `netpol-test-eso-demo.sh` pass.
- The default-deny policy is unchanged in effect.
- No secret in Git, evidence or chat. `git grep` for tokens and keys is clean.

## Final summary (at the end)

Give me, in plain English and without analogies:
- what was built and which files were added or changed
- every place where you were unsure or did not verify something
