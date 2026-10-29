#!/usr/bin/env bash
# install-tools.sh - installs the command-line tools the platform needs on Ubuntu 24.04.
# Run it: bash scripts/setup/install-tools.sh (once; the devcontainer runs it when a Codespace is created)
# Changes the cluster: no. It installs programs on this machine (sudo).
#
# What it does:
#   1. Installs base packages.
#        sudo apt-get install -y curl jq git age ca-certificates openssl
#   2. Installs Docker Engine if it is missing and adds you to the docker group.
#        curl -fsSL https://get.docker.com | sudo sh
#   3. Installs the latest stable kubectl, the latest kind and SOPS release, the
#      Flux CLI and the kubectl-cnpg plugin into /usr/local/bin.
#        curl -fsSLo /tmp/kubectl https://dl.k8s.io/release/<version>/bin/linux/amd64/kubectl
#        curl -fsSL https://fluxcd.io/install.sh | sudo bash
#   4. Prints the installed versions.
#
# What you should see: one "==> <tool>" line per tool, then the versions and
#   "Done. On a VM: log out and back in (docker group). Then run: flux check --pre".
# If it fails: a download error stops the script (set -e); run it again. On a VM
#   without the new group, docker needs a new login.
# Needs: Ubuntu 24.04 (amd64), sudo, internet access.
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
sudo chmod 755 "$BIN/flux"   # the installer can leave the binary non-executable for other users

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
