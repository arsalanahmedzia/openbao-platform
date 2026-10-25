# Project context

This repository contains a Kubernetes platform managed by Flux (GitOps).

## Goal
Kubernetes platform managed entirely by Flux (GitOps); the only manual step is
`flux bootstrap`:
- cert-manager (self-signed root CA -> CA issuer), Traefik ingress (HTTPS)
- CloudNativePG: HA PostgreSQL, backups via Barman Cloud plugin to in-cluster S3
  (e.g. SeaweedFS), point-in-time recovery
- OpenBao in HA mode with PostgreSQL storage backend, Kubernetes auth, KV v2, policies
- External Secrets Operator: ExternalSecret (pull) and PushSecret (push)
- Bootstrap secrets encrypted in Git with SOPS + age (avoids the OpenBao circular dependency)
- Docs: README, ADRs in docs/adr, runbooks in docs/runbooks, evidence in docs/evidence,
  time log in docs/time-log.md

## Environment
GitHub Codespace (4 cores, 16 GB). kind cluster `openbao-platform`: 1 control plane +
3 workers. Node failure is simulated with `docker stop <worker>`. Scripts: scripts/.

## Rules
- NEVER print, cat, echo or commit secrets: age private key, FLUX_GITHUB_TOKEN,
  OpenBao unseal keys or root token. Only *.sops.yaml files may hold secrets, encrypted.
- Everything in the cluster comes from Git via Flux. No lasting `kubectl apply` by hand;
  if you test something manually, say so and remove it afterwards.
- Pin chart and image versions; do not guess versions or API fields, check the
  official docs or `kubectl explain` and say when unsure.
- Explain each step in plain words before doing it, in full detail (what each command
  and flag does, why, what good output looks like). Do not use analogies to other fields;
  do not assume prior knowledge of the user's background. After each stage, show the verification commands and what good output looks like.
- Ask before running anything destructive or anything that costs money.
- Save useful command output to docs/evidence/ and propose a short ADR for each
  design decision (problem, options, choice, trade-off).
- Do not mention or create anything outside this repo.
