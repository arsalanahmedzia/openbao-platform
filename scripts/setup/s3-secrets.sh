#!/usr/bin/env bash
# s3-secrets.sh - generates the S3 keys for SeaweedFS and writes them as two SOPS-encrypted files.
#
# In plain words:
#   PostgreSQL stores its backups in SeaweedFS, which speaks S3 (a common way
#   to store files over HTTP). Both sides need the same access key and secret
#   key: SeaweedFS to accept them, PostgreSQL to use them. This script makes
#   up one random key pair and writes it into two Kubernetes Secret files, one
#   for each side.
#
#   Both files are encrypted with SOPS before they are saved, so they can be
#   committed to Git safely. Flux decrypts them in the cluster after a push.
#   The keys are never printed. Because new keys would make old backups
#   unreadable, the script refuses to overwrite existing files unless you pass
#   --force.
#
# Run it: bash scripts/setup/s3-secrets.sh (once; --force replaces the files)
# Changes the cluster: no. It writes repo files; Flux applies them after a push.
#   --force makes new keys: backups written with the old keys can then not be read.
#
# What it does:
#   1. Refuses to run if a file exists, unless --force is given.
#   2. Generates one access key and one secret key.
#        openssl rand -hex 10 ; openssl rand -hex 20
#   3. Writes infrastructure/storage/seaweedfs-s3-config.sops.yaml (Secret
#      storage/seaweedfs-s3-config: s3.json identities file plus ACCESS_KEY_ID /
#      ACCESS_SECRET_KEY for the bucket Job) and
#      infrastructure/storage/s3-credentials.sops.yaml (Secret
#      databases/s3-credentials for the CloudNativePG backups).
#   4. Encrypts both files in place with the public key from .sops.yaml.
#        sops --encrypt --in-place <file>
#
# What you should see: "Encrypted files written:" with both paths. The keys are
#   never printed.
# If it fails: ".sops.yaml has no age public key yet" means set the recipient in
#   .sops.yaml first. If encryption fails, the trap deletes the unencrypted files.
# Needs: sops, openssl, jq, the age public key in .sops.yaml.
set -euo pipefail
cd "$(dirname "$0")/../.."

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
