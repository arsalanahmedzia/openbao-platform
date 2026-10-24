#!/usr/bin/env bash
# Installs the CLI tools needed to run the platform on a fresh Ubuntu 24.04 host (e.g. EC2).
# Run once:  bash scripts/install-tools.sh   (then log out and back in for the docker group)
set -euo pipefail

ARCH=amd64
BIN=/usr/local/bin

latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name; }

echo "==> Base packages"
sudo apt-get update -y
sudo apt-get install -y curl jq git age ca-certificates openssl

echo "==> Docker Engine"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
fi

echo "==> kubectl"
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
sudo install -m 0755 /tmp/kubectl "$BIN/kubectl"

echo "==> kind"
KIND_VERSION=$(latest kubernetes-sigs/kind)
curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
sudo install -m 0755 /tmp/kind "$BIN/kind"

echo "==> Flux CLI"
curl -fsSL https://fluxcd.io/install.sh | sudo bash

echo "==> SOPS"
SOPS_VERSION=$(latest getsops/sops)
curl -fsSLo /tmp/sops "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${ARCH}"
sudo install -m 0755 /tmp/sops "$BIN/sops"

echo "==> kubectl-cnpg plugin"
curl -fsSL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh \
  | sudo sh -s -- -b "$BIN"

# The OpenBao CLI is not installed locally: we run `bao` inside the OpenBao pods
# with `kubectl exec`, so no extra binary is needed on the host.

echo
echo "==> Installed versions"
docker --version || true
kubectl version --client
kind version
flux --version
sops --version
age --version
kubectl cnpg version || true
echo
echo "Done. On a VM: log out and back in (docker group). Then run: flux check --pre"
