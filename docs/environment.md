# Demo environment

The platform is demonstrated on a 4-node kind cluster (1 control plane, 3 workers)
running inside a **GitHub Codespace** (4 cores, 16 GB). Everything inside the cluster
is deployed by Flux from this repository.

The Codespace was chosen because it runs entirely in the browser: no tools, keys or
clusters on the operator's local machine, no inbound ports or SSH to manage, and
the same `devcontainer.json` reproduces the environment for anyone.

## Host

| Setting | Value | Reason |
| --- | --- | --- |
| Environment | GitHub Codespace, 4-core / 16 GB | Enough for 4 kind nodes with all components |
| Image | `devcontainers/base:noble` (Ubuntu 24.04) + docker-in-docker | Standard, well-supported |
| Tools | Installed by `scripts/install-tools.sh` on creation | Reproducible |
| Config | [`.devcontainer/devcontainer.json`](../.devcontainer/devcontainer.json) | Versioned with the repo |

## Secrets used by the environment

Stored as **Codespaces user secrets** (GitHub settings, encrypted, injected as env vars),
never in the repo or on a local disk:

| Secret | Purpose |
| --- | --- |
| `SOPS_AGE_KEY` | age private key, lets Flux decrypt SOPS secrets |
| `FLUX_GITHUB_TOKEN` | fine-grained token for `flux bootstrap` (limited to this repo, with expiry) |
| `GITHUB_USER` | GitHub user name |

The age key and the OpenBao unseal keys are additionally kept in a password manager.

## Setup

1. Repository on GitHub -> **Code -> Codespaces -> New with options** -> 4-core machine.
2. Wait for `postCreateCommand` (installs the tools).
3. In the Codespace terminal:

```bash
flux check --pre
bash scripts/bootstrap.sh
flux get kustomizations --watch
```

## Access to the OpenBao UI

kind maps the ingress to `127.0.0.1:443` inside the Codespace. Codespaces forwards
that port to a private, GitHub-authenticated URL (Ports tab), so the UI is reachable
over HTTPS without exposing anything publicly.

## Cost and quota

- GitHub's free Codespaces quota is limited per month (check *Settings -> Billing*);
  a 4-core machine uses it four times as fast as a 2-core one.
- A spending limit is set so usage beyond the quota is capped.
- The Codespace is stopped when not in use (idle timeout) and deleted after the review.

## Fallback: AWS EC2

If the Codespace runs out of quota or resources, the same scripts run on an EC2
t3.xlarge (Ubuntu 24.04). Terminal access then goes through **AWS Systems Manager
Session Manager** in the browser: no SSH port opened, no key pair on a local machine.

## Demo simplification

All kind "nodes" are containers on one host, so a node failure is simulated with
`docker stop <worker>`. In production the nodes would be separate machines in
separate failure domains.
