# ── Server1 cluster — platform ───────────────────────────────────────────────
# Deploys Gateway API CRDs, Cilium CNI, and Longhorn storage.
# Run after bootstrap.
#
# Usage:
#   cd iac/clusters/server1/platform
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.10.0"

  # TODO: migrate to MinIO S3 backend once the server3 cluster is running.
  # backend "s3" {
  #   bucket                      = "terraform-state"
  #   key                         = "clusters/server1/platform/terraform.tfstate"
  #   endpoint                    = "https://minio.server3.home"
  #   region                      = "us-east-1"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  # }

}

provider "helm" {
  kubernetes = {
    config_path = "${path.root}/../credentials/kubeconfig"
  }
}

module "platform" {
  source = "../../../modules/platform"

  kubeconfig_path     = "${path.root}/../credentials/kubeconfig"
  cilium_version      = "1.19.2"
  longhorn_version    = "1.11.1"
  gateway_api_version = "1.2.1"

  cilium_values = [
    file("${path.root}/../../helm-values/cilium.yaml"),
    file("${path.root}/../helm-values/cilium.yaml"),
  ]
  longhorn_values = [
    file("${path.root}/../../helm-values/longhorn.yaml"),
    file("${path.root}/../helm-values/longhorn.yaml"),
  ]

  enable_longhorn = true
}
