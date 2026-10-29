#!/usr/bin/env bash
# Hands-on proof that the age key pair works end to end:
#   1. creates a Kubernetes Secret with a random demo password,
#   2. encrypts it with SOPS (uses only the PUBLIC key from .sops.yaml),
#   3. adds it to the infra-configs layer.
# After you commit and push, Flux decrypts it with the PRIVATE key stored in the
# cluster (flux-system/sops-age) and creates the Secret default/sops-demo.
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
