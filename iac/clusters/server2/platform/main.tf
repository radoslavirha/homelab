# ── Server2 cluster — platform ───────────────────────────────────────────────
# Deploys Gateway API CRDs, Cilium CNI, and Longhorn storage.
# Run after bootstrap.
#
# Usage:
#   cd iac/clusters/server2/platform
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.10.0"

  # TODO: migrate to MinIO S3 backend once the server3 cluster is running.
  # backend "s3" {
  #   bucket                      = "terraform-state"
  #   key                         = "clusters/server2/platform/terraform.tfstate"
  #   endpoint                    = "https://minio.server3.homelab.irha.cz"
  #   region                      = "us-east-1"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  # }

}

# Helm provider v3 uses object-typed kubernetes configuration (not a nested block).
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
  longhorn_version    = "1.12.1"
  # Stays on the EXPERIMENTAL channel: server3's Traefik sets providers.kubernetesGateway
  # .experimentalChannel, which makes the chart grant it watch on tcproutes/tlsroutes --
  # deleting those CRDs breaks its informers. Do not "tidy up" to standard-install.
  #
  # 1.6.2 installs a ValidatingAdmissionPolicy, safe-upgrades.gateway.networking.k8s.io,
  # that did not exist at 1.4.0. It denies two things fleet-wide once present:
  #   - applying an EXPERIMENTAL CRD over an existing STANDARD one, and
  #   - applying any gateway.networking.k8s.io CRD with bundle-version v1.0-v1.4.
  # Before this bump the CRDs were a mix -- the six core kinds (Gateway, GatewayClass,
  # HTTPRoute, GRPCRoute, ReferenceGrant, BackendTLSPolicy) were standard@v1.4.0 from a
  # manual client-side kubectl apply, while TCP/TLS/UDPRoute were experimental@v1.4.0
  # from this resource. This bump makes them uniformly experimental, which is what keeps
  # the VAP satisfied on every later apply. If anything ever re-applies standard-channel
  # or <=v1.4 CRDs here, it will now be DENIED -- that is the VAP doing its job, not a
  # regression. To deliberately override it, delete the VAP first.
  # renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api extractVersion=^v(?<version>.*)$
  gateway_api_version = "1.6.2"

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
