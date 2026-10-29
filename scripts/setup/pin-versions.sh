#!/usr/bin/env bash
# pin-versions.sh - writes the newest stable chart versions into the HelmRelease files.
#
# In plain words:
#   Every Helm chart in this repository is pinned to one exact version, so the
#   cluster never changes by itself when a new chart is published (ADR 0001).
#   When the files were first written they held placeholders such as
#   __CERT_MANAGER_VERSION__. This script asks each chart repository for its
#   newest stable version and writes that number in place of the placeholder.
#
#   It only edits files in the repository. Nothing happens in the cluster
#   until you review the diff, commit and push. A file that already has a
#   version is left alone.
#
# Run it: bash scripts/setup/pin-versions.sh (once, when the __PLACEHOLDER__ markers are still in the files)
# Changes the cluster: no. It changes repo files; review the diff, then commit.
#
# What it does:
#   1. Adds and updates the chart repositories (jetstack, traefik, cnpg,
#      external-secrets, openbao, prometheus-community).
#        helm repo add <name> <url> --force-update ; helm repo update
#   2. For each placeholder, looks up the newest stable chart version and
#      replaces the marker in the file. A file that is already pinned is left alone.
#        helm search repo <chart> -o json
#        sed -i "s/<placeholder>/<version>/" <file>
#
# What you should see: one line per chart with its version or "already pinned",
#   then "Done. Review with: git diff".
# If it fails: "no version found for <chart>" means the repository has no such chart.
# Needs: helm, jq, sed, internet access.
set -euo pipefail
cd "$(dirname "$0")/../.."

for tool in helm jq sed; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 1; }
done

echo "==> Adding chart repositories"
helm repo add jetstack         https://charts.jetstack.io                 --force-update >/dev/null
helm repo add traefik          https://traefik.github.io/charts           --force-update >/dev/null
helm repo add cnpg             https://cloudnative-pg.github.io/charts    --force-update >/dev/null
helm repo add external-secrets https://charts.external-secrets.io         --force-update >/dev/null
helm repo add openbao          https://openbao.github.io/openbao-helm      --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

# Newest stable version of a chart, e.g. latest jetstack/cert-manager
latest() {
  helm search repo "$1" -o json | jq -r --arg n "$1" '[.[] | select(.name == $n)][0].version // empty'
}

# pin <file> <placeholder> <repo/chart>
pin() {
  local file=$1 placeholder=$2 chart=$3 version
  version=$(latest "$chart")
  [[ -n "$version" ]] || { echo "no version found for $chart"; exit 1; }
  if grep -q "$placeholder" "$file"; then
    sed -i "s/$placeholder/$version/" "$file"
    printf '%-34s %s\n' "$chart" "$version"
  else
    printf '%-34s already pinned (no %s in %s)\n' "$chart" "$placeholder" "$file"
  fi
}

echo "==> Pinning versions"
pin infrastructure/controllers/cert-manager.yaml     __CERT_MANAGER_VERSION__   jetstack/cert-manager
pin infrastructure/controllers/traefik.yaml          __TRAEFIK_VERSION__        traefik/traefik
pin infrastructure/controllers/cnpg.yaml             __CNPG_VERSION__           cnpg/cloudnative-pg
pin infrastructure/controllers/cnpg.yaml             __BARMAN_PLUGIN_VERSION__  cnpg/plugin-barman-cloud
pin infrastructure/controllers/external-secrets.yaml __ESO_VERSION__            external-secrets/external-secrets
pin apps/openbao/helmrelease.yaml                    __OPENBAO_VERSION__        openbao/openbao
pin apps/monitoring/helmrelease.yaml                 __KPS_VERSION__            prometheus-community/kube-prometheus-stack

echo
echo "Done. Review with: git diff"
