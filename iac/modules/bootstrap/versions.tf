terraform {
  required_version = ">= 1.10.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      # 0.11.0 stable, released 2026-04-27. Six commits past 0.11.0-beta.2 and none
      # of them touch the two defects this module works around -- talos_machine_secrets
      # still drops machine_secrets on update with UseStateForUnknown missing from the
      # CAs, cluster secret and tokens. So talos_secrets_contract stays frozen and its
      # ignore_changes stays. Verified against the beta.2...0.11.0 commit range 2026-09-13.
      version = "0.11.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.8.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.4"
    }
  }
}
