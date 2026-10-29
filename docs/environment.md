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
| Tools | Installed by `scripts/setup/install-tools.sh` on creation | Reproducible |
| Config | [`.devcontainer/devcontainer.json`](../.devcontainer/devcontainer.json) | Versioned with the repo |

## Secrets used by the environment

Stored as **Codespaces user secrets** (GitHub settings, encrypted, injected as
env vars, visible only to Codespaces of this repository), never in the repo:

| Secret | Purpose | What it really is (checked 2026-10-26) |
| --- | --- | --- |
| `SOPS_AGE_KEY` | age private key, lets Flux decrypt SOPS secrets | age private key |
| `FLUX_GITHUB_TOKEN` | token for `flux bootstrap` | **The `gh` CLI login token** (OAuth, prefix `gho_`), saved with `gh auth token \| gh secret set FLUX_GITHUB_TOKEN --user --app codespaces --repos <repo>`. Scopes: `repo`, `workflow`, `codespace:secrets`, `gist`, `read:org`. **No expiry. Valid for every repository of the account**, not only this one. Same token as the `gh` login the scripts use for Codespaces secrets. |
| `GITHUB_USER` | GitHub user name | not secret |
| `OPENBAO_UNSEAL_KEYS` | the 5 OpenBao key shares (JSON list), for `scripts/after-restart/openbao-unseal.sh` | written by `scripts/openbao/openbao-init.sh` |
| `OPENBAO_ROOT_TOKEN` | OpenBao root token, for the configure/policy scripts | written by `scripts/openbao/openbao-init.sh`; to be revoked (`scripts/openbao/openbao-revoke-root.sh`) |

Checked with `bash scripts/checks/github-access-check.sh` (prints token types and
scopes, never the values). An earlier version of this page said
`FLUX_GITHUB_TOKEN` was a fine-grained token limited to this repository with an
expiry; that was the plan, not what was done. Flux itself does **not** use this
token after bootstrap: it reads Git through a **read-only deploy key**
(`flux-system-main-flux-system-./clusters/demo`, `read_only=true`).

The age key and the OpenBao unseal keys are additionally kept in a password
manager (owner's statement, not checked here).

## Manual GitHub steps (owner checklist)

These are done in the GitHub web UI by the account owner; nothing here can be
done by Flux or by the scripts. Re-run `bash scripts/checks/github-access-check.sh`
afterwards to confirm.

**Now**
- [ ] **Two-factor authentication** on the GitHub account, preferably a passkey
      or security key (Settings -> Password and authentication). Whoever controls
      the account controls the repository, the Codespaces secrets (unseal keys,
      root token, age key) and therefore the cluster.
- [ ] **Branch protection / ruleset on `main`** (repository Settings -> Rules ->
      Rulesets, or Branches): block force pushes and branch deletion. Requiring
      pull requests would also block the direct pushes this project uses (and
      `flux bootstrap` writes to `main`), so leave that off for the demo and
      note it as a production setting.
- [ ] **Replace `FLUX_GITHUB_TOKEN`** with a fine-grained personal access token
      limited to this repository, with an expiry date (Settings -> Developer
      settings -> Fine-grained tokens). It is only needed for a new
      `flux bootstrap`. Permissions per the Flux documentation (check them there
      before creating the token): Administration read/write (to add the deploy
      key), Contents read/write, Metadata read. Store it with
      `gh secret set FLUX_GITHUB_TOKEN --user --app codespaces --repos <repo>`
      (value through stdin, never as an argument).

**At the end of the review**
- [ ] Revoke the `gh` OAuth token: Settings -> Applications -> Authorized OAuth
      Apps -> GitHub CLI -> Revoke (this also ends every `gh` login that uses it).
- [ ] Delete the Codespaces secrets `FLUX_GITHUB_TOKEN`, `SOPS_AGE_KEY`,
      `OPENBAO_UNSEAL_KEYS`, `OPENBAO_ROOT_TOKEN` (Settings -> Codespaces).
- [ ] Delete the deploy key `flux-system-main-flux-system-./clusters/demo` and any
      other stale deploy keys (repository Settings -> Deploy keys).
- [ ] Delete the Codespace (this also deletes the cluster and `~/openbao-init.json`).

## Setup

1. Repository on GitHub -> **Code -> Codespaces -> New with options** -> 4-core machine.
2. Wait for `postCreateCommand` (installs the tools).
3. In the Codespace terminal:

```bash
flux check --pre
bash scripts/setup/bootstrap.sh
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

## Known Codespaces quirk: kind nodes without network

On the Codespace VM the legacy iptables `FORWARD` policy is `DROP` and only knows the
default `docker0` bridge. The kind bridge (`br-...`) is covered only by the nftables
rules, so traffic from the kind nodes is dropped and image pulls fail with
`lookup ghcr.io ... i/o timeout` (pods stuck in `ImagePullBackOff`).
`scripts/setup/bootstrap.sh` (`fix_kind_network`) adds `ACCEPT` rules for the kind bridge
and, if a node cannot resolve names, points its `/etc/resolv.conf` at the host resolver.
The iptables rules are not persistent: they are re-applied whenever `bootstrap.sh` runs.

## Demo simplification

All kind "nodes" are containers on one host, so a node failure is simulated with
`docker stop <worker>`. In production the nodes would be separate machines in
separate failure domains.
