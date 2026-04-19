terraform {
  required_version = ">= 1.10.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0-beta.2"
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
