# openbao.reader — browse and read application secrets in the `secret` KV v2 mount.
# Reading a value is the point of this rung: it can see every secret, and change none.
path "secret/data/*" {
  capabilities = ["read"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
