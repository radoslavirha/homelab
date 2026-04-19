terraform {
  required_version = ">= 1.10.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.4"
    }
  }
}
