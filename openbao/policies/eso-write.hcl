# External Secrets (PushSecret, push): only below secret/pushed/.
# ESO writes the marker custom_metadata managed-by=external-secrets to the
# metadata path before the data, and with deletionPolicy Delete it deletes
# both (providers/v1/vault/client_push.go, ESO v2.14.0). See ADR 0005.
path "secret/data/pushed/*" {
  capabilities = ["create", "update", "delete"]
}
path "secret/metadata/pushed/*" {
  capabilities = ["create", "update", "delete"]
}
