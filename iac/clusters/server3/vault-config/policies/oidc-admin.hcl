# openbao.admin — everything, including sys/, auth/ and policies.
# Same grant as the userpass `admin` policy (docs/iac.md step 3.g), plus `patch`.
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}
