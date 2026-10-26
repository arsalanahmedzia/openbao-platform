# Task brief: External Secrets stage (OpenBao to Kubernetes and back)

Read CLAUDE.md first. Everything in CLAUDE.md still applies. This brief adds the rules for this stage.

## Goal

Connect the cluster to OpenBao with the External Secrets Operator (ESO, already installed by Flux as a HelmRelease, chart 2.14.0):

1. **Pull:** an `ExternalSecret` reads `secret/demo/hello` from OpenBao and creates a normal Kubernetes Secret.
2. **Push:** a `PushSecret` writes a Kubernetes Secret into OpenBao under `secret/pushed/`.
3. ESO logs in to OpenBao with **Kubernetes auth** as service account `external-secrets` in namespace `external-secrets`, role `external-secrets`, policies `eso-read` and `eso-write`. **No root token, no static token.**

## What already exists (verify in the repo, do not assume)

- OpenBao runs in HA (3 pods, namespace `openbao`), unsealed by `scripts/openbao-unseal.sh`, HTTPS through Traefik at `openbao.demo.local` with a certificate from the `demo-ca` ClusterIssuer.
- `scripts/openbao-configure.sh` created KV v2 at `secret/`, Kubernetes auth, policies `eso-read` and `eso-write`, role `external-secrets`, and the test secret `secret/demo/hello` (message `hello-from-openbao`).
- ESO is installed in namespace `external-secrets`. Check the installed chart version (2.14.0) and use the API versions of the CRDs it installs. **Do not guess API versions.**
- Flux layers use `dependsOn`. Add a new layer or folder that depends on OpenBao and on the ESO controllers, following the pattern of the existing layers.

## Rules for this stage (same as the OpenBao stage)

- You write files and scripts and commit them. **I run every command that touches the cluster.** You do not run kubectl, flux, bao or bootstrap yourself.
- One short script per step, with a clear name and comments, so I can run `bash scripts/<name>.sh`.
- Before each step: say in one or two plain sentences what it does and why. After each step: say which output means it worked. Then wait for me.
- No secret values in chat, evidence, commits or logs. The demo value `hello-from-openbao` is not secret and may be shown. Never print tokens.
- Everything in the cluster comes from Git through Flux. No lasting `kubectl apply` by hand.
- Pin versions. Commit small, one concern per commit, plain messages, no `Co-Authored-By` or generated-by lines.
- If you must choose between options, ask me with a question and say which one you recommend.

## Decisions to ask me about (use AskUserQuestion, recommend one)

1. **Store scope:** `ClusterSecretStore` (one store for all namespaces) or `SecretStore` per namespace.
2. **How ESO trusts OpenBao's certificate:** use the CA from `demo-root-ca` (recommended), or talk to the in-cluster HTTP/HTTPS service some other way. Check how the OpenBao listener is configured before proposing.
3. **Which address ESO uses:** the in-cluster Service (recommended) or the Traefik hostname.
4. **Refresh interval** for the ExternalSecret (short, for a visible demo).

## Steps

1. **Inspect (read-only).** Read the repo. Report: OpenBao Service names and ports, listener TLS setting, ESO CRD API versions, existing layer names, namespaces. Ask the decisions above.
2. **Policy check.** Decide whether `eso-write` needs rights on `secret/metadata/pushed/*` for PushSecret (PushSecret may need metadata for its managed-by markers and for deletion). **Tell me before changing any policy.** If a change is needed, change `scripts/openbao-configure.sh` so it stays repeatable, and give me a small script to apply it.
3. **ClusterSecretStore** with the Vault provider (works with OpenBao): server address, `path: secret`, `version: v2`, Kubernetes auth with `mountPath: kubernetes`, `role: external-secrets`, `serviceAccountRef` for `external-secrets`, CA from the chosen source. Commit it into the new Flux layer. Script: show the store status (`Valid` / `Ready`).
4. **ExternalSecret (pull)** in a demo namespace: map `secret/demo/hello` key `message` to a Kubernetes Secret. Script: show that the Secret exists and that its decoded value equals `hello-from-openbao`. It is a demo value, so showing it is fine.
5. **Prove the refresh:** a script changes the value in OpenBao (as the ESO login, not root), waits for the refresh interval, and shows that the Kubernetes Secret changed. Then restore the original value.
6. **PushSecret (push):** push a Kubernetes Secret with a non-sensitive demo value into `secret/pushed/<name>`. The source Secret must not be a real secret. Set `updatePolicy`, `deletionPolicy` and `creationPolicy` on purpose and explain each choice. Script: read the pushed value back **as the ESO login** and show it.
7. **Prove least privilege:** as the ESO login, reading `secret/demo/hello` works, writing under `secret/pushed/` works, writing under `secret/demo/` is denied. Reuse the checks from `openbao-configure.sh`.
8. **Evidence:** a script writes `docs/evidence/05-external-secrets.txt` with the outputs above. Check the file for tokens or secret values before committing.
9. **Docs:** ADR 0005 (store scope, CA trust, refresh interval, push policies, why no root or static token), a runbook (`docs/runbooks/external-secrets.md`: how to check the store, how to debug a failing ExternalSecret), README section, time log entry. If you changed the policy, update ADR 0004 with one note line.

## Acceptance criteria

- The store reports valid and ready.
- The pulled Secret has the right value, and a change in OpenBao reaches it after the refresh interval.
- The pushed value is readable in OpenBao, and the ESO login is denied outside `secret/pushed/`.
- Flux shows every layer `True`, including the new one, from a clean reconcile.
- No secret in Git, evidence or chat. `git grep` for tokens and keys is clean.

## Final summary (at the end)

Give me, in plain English and without analogies:
- what was built and which files were added
- five sentences I should be able to explain, each with its reason
- every place where you were unsure or did not verify something
- what is left for the failure-test stage
