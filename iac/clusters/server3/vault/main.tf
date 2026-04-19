# ── Server3 cluster — secrets ──────────────────────────────────────────────
# Deploys OpenBao — the central secrets backend for all clusters.
# Run after platform, before apps.
#
# After apply, run the init ceremony manually:
#   kubectl exec -n openbao openbao-0 -- bao operator init   # save keys + root token
#   kubectl exec -n openbao openbao-0 -- bao operator unseal  # repeat 3×
#   bao login <root-token>
#   bao secrets enable -path=secret kv-v2
#
# Usage:
#   cd iac/clusters/server3/secrets
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.10.0"

  # Same chicken-and-egg situation as bootstrap — local state until MinIO is live.
  # backend "s3" { ... key = "clusters/server3/secrets/terraform.tfstate" ... }
}

provider "helm" {
  kubernetes = {
    config_path = "${path.root}/../credentials/kubeconfig"
  }
}

module "secrets" {
  source = "../../../modules/secrets"

  kubeconfig_path = "${path.root}/../credentials/kubeconfig"

  # Check latest: helm search repo openbao/openbao --versions
  openbao_version = "0.10.0"

  openbao_values = file("${path.root}/../helm-values/openbao.yaml")
}
