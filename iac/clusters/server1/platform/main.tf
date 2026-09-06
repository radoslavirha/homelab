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
  #   endpoint                    = "https://minio.server3.homelab.irha.cz"
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
  # renovate: datasource=helm registryUrl=https://helm.cilium.io depName=cilium
  cilium_version      = "1.19.2"
  # renovate: datasource=helm registryUrl=https://charts.longhorn.io depName=longhorn
  longhorn_version    = "1.11.1"
  # 1.4.0, not 1.2.1: Cilium 1.19.2 installed the standard-channel CRDs at v1.4.0
  # underneath Terraform, so the old pin no longer described any cluster. Kept on the
  # EXPERIMENTAL channel because server3's Traefik sets providers.kubernetesGateway
  # .experimentalChannel, which makes the chart grant it watch on tcproutes/tlsroutes --
  # deleting those CRDs breaks its informers. Do not "tidy up" to standard-install.
  # renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api extractVersion=^v(?<version>.*)$
  gateway_api_version = "1.4.0"

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
