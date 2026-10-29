#!/usr/bin/env bash
# sops-demo.sh - proves the age key pair works: writes an encrypted demo Secret for Flux to decrypt.
# Run it: bash scripts/setup/sops-demo.sh (once, to show SOPS end to end)
# Changes the cluster: no. It writes infrastructure/configs/sops-demo.sops.yaml and
#   adds it to infrastructure/configs/kustomization.yaml. After your commit and push,
#   Flux decrypts it with the private key in flux-system/sops-age and creates default/sops-demo.
#
# What it does:
#   1. Writes a Secret with a random demo password.
#        openssl rand -base64 18
#   2. Encrypts it with the public key from .sops.yaml.
#        sops --encrypt --in-place infrastructure/configs/sops-demo.sops.yaml
#   3. Adds the file to the infra-configs layer if it is not listed yet.
#
# What you should see: the encrypted file (values as ENC[...]) and the line
#   "Next: git add -A && git commit -m 'Add SOPS demo secret' && git push".
#   The script does not run git itself.
# If it fails: ".sops.yaml has no age public key yet" means set the recipient first.
# Needs: sops, openssl, the age public key in .sops.yaml.
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v sops >/dev/null || { echo "missing tool: sops"; exit 1; }
grep -q 'age1' .sops.yaml || { echo ".sops.yaml has no age public key yet"; exit 1; }

OUT=infrastructure/configs/sops-demo.sops.yaml
PASSWORD=$(openssl rand -base64 18)

cat > "$OUT" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: sops-demo
  namespace: default
type: Opaque
stringData:
  password: "$PASSWORD"
EOF

sops --encrypt --in-place "$OUT"

grep -q 'sops-demo.sops.yaml' infrastructure/configs/kustomization.yaml \
  || echo '  - sops-demo.sops.yaml' >> infrastructure/configs/kustomization.yaml

echo "Encrypted file written to $OUT:"
echo
cat "$OUT"
echo
echo "Next: git add -A && git commit -m 'Add SOPS demo secret' && git push"
