#!/usr/bin/env bash
# bootstrap.sh - creates the kind cluster, the SOPS key Secret and installs Flux.
#
# In plain words:
#   This is the only manual step of the whole platform. It creates an empty
#   Kubernetes cluster and installs Flux; from then on Flux reads this Git
#   repository and builds everything else by itself (that way of working is
#   called GitOps).
#
#   It does three things in order. First it creates the kind cluster: four
#   Docker containers that act as one control plane and three worker nodes.
#   Second it stores the age private key in the cluster as the Secret
#   sops-age, so Flux can decrypt the encrypted *.sops.yaml files; this is the
#   only Secret ever created by hand. Third it runs flux bootstrap, which
#   installs Flux and connects it to this repository on GitHub.
#
#   If the cluster already exists it is reused, so running the script twice
#   does not create a second cluster.
#
# Run it: bash scripts/setup/bootstrap.sh (once per new cluster; after it every change comes through Git)
# Changes the cluster: yes: creates the cluster, the Secret flux-system/sops-age and Flux.
#
# What it does:
#   1. Creates the kind cluster openbao-platform from kind-config.yaml in this
#      folder, or reuses it if it exists. Allows forwarding for the kind bridge
#      and sets a DNS server in the nodes if they cannot resolve names.
#        kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"
#        kubectl wait --for=condition=Ready nodes --all --timeout=180s
#   2. Checks that Flux can be installed.
#        flux check --pre
#   3. Stores the age private key as the Secret sops-age (the only Secret
#      created by hand), so Flux can decrypt the *.sops.yaml files.
#        kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=<key> --dry-run=client -o yaml | kubectl apply -f -
#   4. Installs Flux and connects it to this repository (path clusters/demo).
#        flux bootstrap github --owner=<GITHUB_USER> --repository=<GITHUB_REPO> --branch=main --path=clusters/demo --personal
#
# What you should see: "==> 1/4" to "==> 4/4", then "Bootstrap done." and the
#   two flux commands to watch the progress.
# If it fails: "missing tool" means run scripts/setup/install-tools.sh first;
#   "age key not found" means SOPS_AGE_KEY or AGE_KEY_FILE is not set.
# Needs: docker, kind, kubectl, flux. Environment:
#   FLUX_GITHUB_TOKEN  personal access token Flux uses (falls back to GITHUB_TOKEN;
#                      the Codespaces GITHUB_TOKEN has too few rights)
#   GITHUB_USER        your GitHub user name
#   SOPS_AGE_KEY       the age private key (e.g. a Codespaces secret), or
#   AGE_KEY_FILE       a file path (default: ./age.agekey, never committed)
#   GITHUB_REPO        optional, default openbao-platform
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-openbao-platform}"
AGE_KEY_FILE="${AGE_KEY_FILE:-./age.agekey}"
CLUSTER_NAME=openbao-platform
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export GITHUB_TOKEN="${FLUX_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
: "${GITHUB_TOKEN:?set FLUX_GITHUB_TOKEN (or GITHUB_TOKEN)}"
: "${GITHUB_USER:?set GITHUB_USER}"

# Prefer the key from an environment secret, so it never sits on disk in the repo folder.
TMP_KEY=""
if [[ -n "${SOPS_AGE_KEY:-}" ]]; then
  TMP_KEY="$(mktemp)"
  trap 'rm -f "$TMP_KEY"' EXIT
  printf '%s\n' "$SOPS_AGE_KEY" > "$TMP_KEY"
  AGE_KEY_FILE="$TMP_KEY"
fi
[[ -f "$AGE_KEY_FILE" ]] || { echo "age key not found: set SOPS_AGE_KEY or AGE_KEY_FILE"; exit 1; }

for tool in docker kind kubectl flux; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool (run scripts/setup/install-tools.sh)"; exit 1; }
done

# Codespaces quirk: the host's legacy iptables FORWARD policy is DROP and only
# knows the default docker0 bridge, so the kind nodes (on their own bridge) get
# no outbound traffic and cannot pull images. We allow forwarding for the kind
# bridge, and make sure the nodes can resolve DNS names.
fix_kind_network() {
  local bridge dns node
  bridge="br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)"
  if command -v iptables-legacy >/dev/null && sudo iptables-legacy -S FORWARD | grep -q -- '-P FORWARD DROP'; then
    sudo iptables-legacy -C FORWARD -i "$bridge" -j ACCEPT 2>/dev/null || sudo iptables-legacy -I FORWARD -i "$bridge" -j ACCEPT
    sudo iptables-legacy -C FORWARD -o "$bridge" -j ACCEPT 2>/dev/null || sudo iptables-legacy -I FORWARD -o "$bridge" -j ACCEPT
    echo "allowed forwarding for kind bridge $bridge"
  fi
  # Use the host's own resolver if the node cannot resolve names by itself.
  dns="$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf)"
  dns="${dns:-8.8.8.8}"
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" getent hosts ghcr.io >/dev/null 2>&1 \
      || docker exec "$node" sh -c "echo 'nameserver $dns' > /etc/resolv.conf"
  done
}

echo "==> 1/4 kind cluster"
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "cluster $CLUSTER_NAME already exists, reusing it"
else
  kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"
fi
fix_kind_network
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "==> 2/4 Flux pre-flight checks"
flux check --pre

echo "==> 3/4 SOPS age key secret (the only secret created by hand)"
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey="$AGE_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> 4/4 Flux bootstrap"
flux bootstrap github \
  --owner="$GITHUB_USER" \
  --repository="$GITHUB_REPO" \
  --branch=main \
  --path=clusters/demo \
  --personal

echo
echo "Bootstrap done. Watch progress with:"
echo "  flux get kustomizations --watch"
echo "  flux get helmreleases -A"
