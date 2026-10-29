#!/usr/bin/env bash
# openbao-db-secret.sh - generates OpenBao's PostgreSQL password and writes it as two SOPS-encrypted files.
# Run it: bash scripts/setup/openbao-db-secret.sh (once; --force rotates the password)
# Changes the cluster: no. It writes repo files; Flux applies them after a push.
#   After --force the OpenBao pods must be restarted (runbook openbao-init-unseal.md, section 4).
#
# What it does:
#   1. Refuses to run if a file exists, unless --force is given.
#   2. Generates one password.
#        openssl rand -hex 24
#   3. Writes apps/database/pg-openbao-openbao.sops.yaml (Secret
#      databases/pg-openbao-openbao, type basic-auth; CloudNativePG sets this
#      password on the role openbao) and apps/openbao/openbao-db.sops.yaml
#      (Secret openbao/openbao-db: BAO_PG_CONNECTION_URL with the same password).
#   4. Encrypts both files in place with the public key from .sops.yaml.
#        sops --encrypt --in-place <file>
#
# What you should see: "Encrypted files written:" with both paths. The password
#   is never printed.
# If it fails: ".sops.yaml has no age public key yet" means set the recipient in
#   .sops.yaml first. If encryption fails, the trap deletes the unencrypted files.
# Needs: sops, openssl, the age public key in .sops.yaml.
set -euo pipefail
cd "$(dirname "$0")/../.."

for tool in sops openssl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 1; }
done
grep -q 'age1' .sops.yaml || { echo ".sops.yaml has no age public key yet"; exit 1; }

PG_SECRET=apps/database/pg-openbao-openbao.sops.yaml
BAO_SECRET=apps/openbao/openbao-db.sops.yaml

if [[ "${1:-}" != "--force" ]]; then
  for f in "$PG_SECRET" "$BAO_SECRET"; do
    [[ -e "$f" ]] && { echo "$f already exists; use --force to replace (rotates the password)"; exit 1; }
  done
fi

# If anything fails before encryption completes, delete the (plaintext) files.
encrypted=false
trap '$encrypted || rm -f "$PG_SECRET" "$BAO_SECRET"' EXIT
umask 077
mkdir -p apps/openbao

# Hex only: safe inside a URL without escaping.
PASSWORD=$(openssl rand -hex 24)

cat > "$PG_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pg-openbao-openbao
  namespace: databases
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: openbao
  password: "$PASSWORD"
EOF

cat > "$BAO_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openbao-db
  namespace: openbao
type: Opaque
stringData:
  BAO_PG_CONNECTION_URL: "postgres://openbao:$PASSWORD@pg-openbao-rw.databases.svc:5432/openbao?sslmode=require"
EOF

sops --encrypt --in-place "$PG_SECRET"
sops --encrypt --in-place "$BAO_SECRET"
encrypted=true

echo "Encrypted files written:"
echo "  $PG_SECRET"
echo "  $BAO_SECRET"
echo "Check: grep -c 'ENC\[' <file>   (every value should be ENC[...])"
