# ── Server3 cluster — apps ─────────────────────────────────────────────────
# Installs ArgoCD and applies the ArgoCD self-management Application.
# Run after vault, as the vault provider reads the ArgoCD admin password hash from OpenBao.
#
# Prerequisites:
#   1. Port-forward OpenBao:
#        kubectl port-forward -n openbao svc/openbao 8200:8200
#   2. Export vault credentials:
#        export VAULT_ADDR=http://127.0.0.1:8200
#        export VAULT_TOKEN=$(cat ~/.vault-token)   # or: bao login <root-token>
#   3. Ensure the ArgoCD secret exists in OpenBao:
#        bao kv put secret/server3/argocd adminPasswordHash='$2a$10$...'
#        # Generate hash: htpasswd -bnBC 10 "" YOUR_PASSWORD | tr -d ':\n'
#
# Usage:
#   cd iac/clusters/server3/apps
#   terraform init && terraform apply -auto-approve

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

  # Same chicken-and-egg situation as bootstrap — local state until MinIO is live.
  # backend "s3" { ... key = "clusters/server3/apps/terraform.tfstate" ... }
}

provider "helm" {
  kubernetes = {
    config_path = "${path.root}/../credentials/kubeconfig"
  }
}

provider "vault" {
  # Reads VAULT_ADDR and VAULT_TOKEN from environment.
  # No address hardcoded — set before running terraform apply.
}

provider "kubectl" {
  config_path       = "${path.root}/../credentials/kubeconfig"
  apply_retry_count = 5
}

provider "kubernetes" {
  config_path = "${path.root}/../credentials/kubeconfig"
}

module "apps" {
  source = "../../../modules/apps"

  kubeconfig_path = "${path.root}/../credentials/kubeconfig"

  # Check latest: helm search repo argo/argo-cd --versions
  argocd_chart_version = "9.5.2"

  argocd_values = file("${path.root}/../../../../gitops/helm-values/server3/argocd.yaml")

  # ArgoCD admin password hash is stored in OpenBao at secret/server3/argocd.adminPasswordHash.
  argocd_vault_secret_path = "server3/argocd"

  # ArgoCD self-management Application — ArgoCD will manage its own Helm release from git.
  # Chart version in this manifest must match argocd_chart_version above.
  argocd_self_manage_yaml = file("${path.root}/../../../../gitops/argocd-manifests/ArgoCD.yaml")
}
