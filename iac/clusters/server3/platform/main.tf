# ── Server3 cluster — platform ──────────────────────────────────────────────
# Deploys Gateway API CRDs, Cilium CNI, and Longhorn storage.
# Run after bootstrap, before secrets.
#
# Usage:
#   cd iac/clusters/server3/platform
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.10.0"

  # Same chicken-and-egg situation as bootstrap — local state until MinIO is live.
  # backend "s3" { ... key = "clusters/server3/platform/terraform.tfstate" ... }

}

provider "helm" {
  kubernetes = {
    config_path = "${path.root}/../credentials/kubeconfig"
  }
}

module "platform" {
  source = "../../../modules/platform"

  kubeconfig_path = "${path.root}/../credentials/kubeconfig"
  cilium_version      = "1.19.2"
  longhorn_version    = "1.11.1"
  gateway_api_version = "1.2.1"

  cilium_values   = file("${path.root}/../helm-values/cilium.yaml")
  longhorn_values = file("${path.root}/../helm-values/longhorn.yaml")

  # ── Feature flags ─────────────────────────────────────────────────────────
  enable_longhorn = true
}
