terraform {
  # 1.11 is the floor for write-only arguments, which keep the OIDC client secret out of state.
  required_version = ">= 1.11.0"

  required_providers {
    vault = {
      source = "hashicorp/vault"
      # 5.x, unlike modules/apps (~> 4.0): the ephemeral vault_kv_secret_v2 and
      # oidc_client_secret_wo used in oidc.tf do not exist in 4.x. Separate root module,
      # separate lock file, so the two do not have to move together.
      version = "5.11.0"
    }
  }
}
