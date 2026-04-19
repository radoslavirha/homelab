# ── Server3 cluster — secrets ──────────────────────────────────────────────
# Deploys OpenBao — the central secrets backend for all clusters.
# Run after platform, before apps.
#
# After apply, run the init ceremony manually:
#   kubectl exec -n openbao openbao-0 -- bao operator init   # save unseal keys + root token
#   kubectl exec -n openbao openbao-0 -- bao operator unseal <key>  # repeat 3× with different keys
#   kubectl port-forward -n openbao svc/openbao 8200:8200 &
#   export BAO_ADDR=http://127.0.0.1:8200
#   bao login <root-token>
#   bao secrets enable -path=secret kv-v2
#
# Usage:
#   cd iac/clusters/server3/vault
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
  source = "../../../modules/vault"

  kubeconfig_path = "${path.root}/../credentials/kubeconfig"

  # Check latest: helm search repo openbao/openbao --versions
  openbao_version = "0.10.0"

  openbao_values = file("${path.root}/../helm-values/openbao.yaml")
}
