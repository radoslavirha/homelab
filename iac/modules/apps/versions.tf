terraform {
  required_version = ">= 1.10.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.1"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}
