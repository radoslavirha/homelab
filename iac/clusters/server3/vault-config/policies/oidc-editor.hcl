# openbao.editor — read and write application secrets in the `secret` KV v2 mount.
# No sys/, no auth/, no policies: an editor changes values, not who may read them.
path "secret/data/*" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list", "delete"]
}

path "secret/delete/*" {
  capabilities = ["update"]
}

path "secret/undelete/*" {
  capabilities = ["update"]
}
