#!/usr/bin/env bash
# Looks up the newest STABLE chart version of each component and writes it into
# the HelmRelease files (replacing the __PLACEHOLDER__ markers).
# Run once, review the diff, then commit. Versions are then fixed in Git, so the
# cluster does not change by itself when a new chart is published.
set -euo pipefail
cd "$(dirname "$0")/.."

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
