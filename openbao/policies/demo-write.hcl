# Demo writer (refresh test, service account eso-demo/demo-writer): change
# values below secret/demo/, the way a person or CI pipeline would. ESO itself
# stays read-only there.
path "secret/data/demo/*" {
  capabilities = ["create", "update"]
}
