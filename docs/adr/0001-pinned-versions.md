# ADR 0001: Pin exact chart and image versions

- Status: accepted
- Date: 2026-10-25

## Problem

Flux installs Helm charts and container images from public repositories. If a
manifest names a moving target (no version, a range such as `1.x`, or the image
tag `latest`), the cluster can change by itself whenever a new version is
published: nothing changes in Git, but the running software does. The platform
must be reproducible (a rebuilt cluster runs the same software) and every change
must be visible as a Git commit.

## Options

1. **Floating versions** (`latest`, semver ranges like `>=1.0.0`): always the
   newest release, no maintenance work, but upgrades happen without review and a
   rebuild weeks later can behave differently.
2. **Exact versions** (chart `version: "0.29.1"`, image `chrislusf/seaweedfs:4.48`):
   same software on every rebuild, upgrades are deliberate commits.
3. **Exact versions plus image digest** (`image@sha256:...`): additionally
   protects against a tag being re-pushed with different content, but is harder
   to read and to update by hand.

## Choice

Option 2. Chart versions are written into the HelmReleases by
`scripts/setup/pin-versions.sh` (newest stable chart at the time of pinning, then
reviewed and committed). Image tags that are set directly in manifests are
checked by hand: the tag must exist on the registry, be pulled successfully
(`docker pull`), and be at least a few weeks old (not released the same day).

Pinned today:

| Component | Chart / image | Version |
| --- | --- | --- |
| cert-manager | chart `jetstack/cert-manager` | v1.21.3 |
| Traefik | chart `traefik/traefik` | 42.1.3 |
| CloudNativePG | chart `cnpg/cloudnative-pg` | 0.29.1 |
| Barman Cloud plugin | chart `cnpg/plugin-barman-cloud` | 0.8.1 |
| External Secrets | chart `external-secrets/external-secrets` | 2.14.0 |
| SeaweedFS | image `chrislusf/seaweedfs` | 4.48 |
| AWS CLI (bucket Job) | image `amazon/aws-cli` | 2.37.13 |

## Trade-off

Upgrades, including security fixes, only happen when someone bumps a version
in Git. Nothing warns us when a pinned version becomes outdated. Next step for
production: an automated update bot (for example Renovate) that opens a pull
request per new version, so upgrades stay reviewed but are not forgotten.
Tags are not digest-pinned, so a re-pushed tag would not be detected.
