# External Secrets (ExternalSecret, pull): read every KV v2 secret and
# read/list its metadata (PushSecret also reads the managed-by marker).
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
