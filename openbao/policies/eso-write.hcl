# External Secrets (PushSecret, push): only below secret/pushed/.
# For each push ESO reads the data path (does it exist?), reads the metadata
# (managed-by marker), writes the marker custom_metadata
# managed-by=external-secrets to the metadata path, then writes the data; with
# deletionPolicy Delete it deletes both (providers/v1/vault/client_push.go,
# ESO v2.14.0). "read" is needed here although eso-read allows secret/data/*:
# OpenBao uses only the most specific matching path pattern, and
# secret/data/pushed/* is more specific than secret/data/*. See ADR 0005.
path "secret/data/pushed/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "secret/metadata/pushed/*" {
  capabilities = ["create", "read", "update", "delete"]
}
