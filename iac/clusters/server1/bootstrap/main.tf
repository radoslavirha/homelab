# ── Server1 cluster — bootstrap ──────────────────────────────────────────────
# Provisions the Talos Linux cluster and writes credentials to ../credentials/.
# Run first before platform or apps.
#
# Usage:
#   cd iac/clusters/server1/bootstrap
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    talos = { source = "siderolabs/talos" }
  }

  # TODO: migrate to MinIO S3 backend once the server3 cluster is running.
  # backend "s3" {
  #   bucket                      = "terraform-state"
  #   key                         = "clusters/server1/bootstrap/terraform.tfstate"
  #   endpoint                    = "https://minio.server3.homelab.irha.cz"
  #   region                      = "us-east-1"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  # }

}

provider "talos" {}

module "bootstrap" {
  source = "../../../modules/bootstrap"

  # ── Cluster identity ──────────────────────────────────────────────────────
  cluster_name = "server1"

  # ── Node network ─────────────────────────────────────────────────────────
  controlplane_ips = ["192.168.1.200"]
  worker_ips       = []
  # cluster_vip    = ""    # set when adding a second controlplane for HA

  # ── Talos ──────────────────────────────────────────────────────────────────
  # Frozen at the bootstrap value. NOT bumped by Renovate, NOT bumped on upgrade.
  talos_secrets_contract = "v1.12.6"

  # renovate: datasource=github-releases depName=siderolabs/talos
  talos_version = "v1.13.10"
  # renovate: datasource=github-releases depName=kubernetes/kubernetes extractVersion=^v(?<version>.*)$
  kubernetes_version = "1.36.4"

  # Schematic includes: siderolabs/iscsi-tools + siderolabs/util-linux-tools
  # Regenerate at https://factory.talos.dev when extensions change.
  talos_schematic_id = "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"

  # ── OS install disk ────────────────────────────────────────────────────────
  # Discovery: talosctl get disks -n 192.168.1.200 --insecure
  # SK hynix BC501 HFM256GDJTNG-8310A
  install_disk_selector = { wwid = "eui.ace42e81750c78a0" }

  # ── Longhorn data disks ────────────────────────────────────────────────────
  # Micron MTFDDAK25 — dedicated SATA SSD mounted at /var/lib/longhorn
  longhorn_disks = {
    "192.168.1.200" = { device = "/dev/disk/by-id/wwn-0x500a0751265f9efe" }
  }

  # ── kube-apiserver OIDC ────────────────────────────────────────────────────
  # Trust THIS cluster's Headlamp provider in Authentik, so a Headlamp login is a
  # Kubernetes identity and RBAC applies to it. Rolled out after the server2 canary
  # was verified end to end on 2026-09-17 (audit log: requests as oidc:radoslav with
  # the headlamp.* groups, no 401s in Headlamp).
  #
  # The issuer's TRAILING SLASH is load-bearing. kube-apiserver compares
  # --oidc-issuer-url to the token's `iss` exactly, and Authentik's per_provider
  # issuer ends in `/`.
  #
  # Claims take the module defaults: username from `sub` prefixed `oidc:`, groups
  # from `roles`. RBAC for those groups:
  # gitops/k8s-manifests/server1/headlamp/ClusterRoleBinding.headlamp-oidc.yaml.
  apiserver_oidc = {
    issuer_url = "https://auth.irha.cz/application/o/headlamp-server1-production/"
    client_id  = "headlamp-server1-production"
  }

  # ── Credentials output ─────────────────────────────────────────────────────
  credentials_dir = "${path.root}/../credentials"
}
