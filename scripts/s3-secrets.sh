#!/usr/bin/env bash
# Generates the S3 credentials for the in-cluster SeaweedFS and writes them as
# two SOPS-encrypted Secrets (one access/secret key pair, used by both):
#   infrastructure/storage/seaweedfs-s3-config.sops.yaml
#       Secret storage/seaweedfs-s3-config: s3.json (SeaweedFS identities file)
#       plus ACCESS_KEY_ID / ACCESS_SECRET_KEY for the bucket Job.
#   infrastructure/storage/s3-credentials.sops.yaml
#       Secret databases/s3-credentials: ACCESS_KEY_ID / ACCESS_SECRET_KEY for
#       CloudNativePG backups.
# The values are never printed. Refuses to overwrite existing files unless
# --force is given (new keys break access to backups written with the old ones).
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in sops openssl jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 1; }
done
grep -q 'age1' .sops.yaml || { echo ".sops.yaml has no age public key yet"; exit 1; }

CONFIG=infrastructure/storage/seaweedfs-s3-config.sops.yaml
CREDS=infrastructure/storage/s3-credentials.sops.yaml

if [[ "${1:-}" != "--force" ]]; then
  for f in "$CONFIG" "$CREDS"; do
    [[ -e "$f" ]] && { echo "$f already exists; use --force to replace (rotates the keys)"; exit 1; }
  done
fi

# If anything fails before encryption completes, delete the (plaintext) files.
encrypted=false
trap '$encrypted || rm -f "$CONFIG" "$CREDS"' EXIT
umask 077

ACCESS_KEY=$(openssl rand -hex 10)
SECRET_KEY=$(openssl rand -hex 20)
S3_JSON=$(jq -cn --arg a "$ACCESS_KEY" --arg s "$SECRET_KEY" \
  '{identities: [{name: "backup", credentials: [{accessKey: $a, secretKey: $s}],
    actions: ["Admin", "Read", "Write"]}]}')

cat > "$CONFIG" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: seaweedfs-s3-config
  namespace: storage
type: Opaque
stringData:
  s3.json: |
    $S3_JSON
  ACCESS_KEY_ID: "$ACCESS_KEY"
  ACCESS_SECRET_KEY: "$SECRET_KEY"
EOF

cat > "$CREDS" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: databases
type: Opaque
stringData:
  ACCESS_KEY_ID: "$ACCESS_KEY"
  ACCESS_SECRET_KEY: "$SECRET_KEY"
EOF

sops --encrypt --in-place "$CONFIG"
sops --encrypt --in-place "$CREDS"
encrypted=true

echo "Encrypted files written:"
echo "  $CONFIG"
echo "  $CREDS"
echo "Check: grep -c 'ENC\[' <file>   (every value should be ENC[...])"
