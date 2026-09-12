# ── Server3 cluster — bootstrap ──────────────────────────────────────────────
# Provisions the Talos Linux cluster and writes credentials to ../credentials/.
# Run first before platform or apps.
#
# Roles: Platform services — MinIO, OpenBao, ArgoCD hub
#
# Usage:
#   cd iac/clusters/server3/bootstrap
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.10.0"

  # State is local until MinIO is bootstrapped on this cluster (chicken-and-egg).
  # Migration: terraform init -migrate-state after MinIO is running.
  # backend "s3" {
  #   bucket                      = "terraform-state"
  #   key                         = "clusters/server3/bootstrap/terraform.tfstate"
  #   endpoint                    = "https://minio.server3.homelab.irha.cz"
  #   region                      = "us-east-1"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   force_path_style            = true
  # }

  required_providers {
    talos = { source = "siderolabs/talos" }
  }
}

provider "talos" {}

module "bootstrap" {
  source = "../../../modules/bootstrap"

  # ── Cluster identity ──────────────────────────────────────────────────────
  cluster_name = "server3"

  # ── Node network ─────────────────────────────────────────────────────────
  controlplane_ips = ["192.168.1.202"]
  worker_ips       = []
  # cluster_vip    = ""    # set when adding a second controlplane for HA

  # ── Talos ──────────────────────────────────────────────────────────────────
  # Frozen at the bootstrap value. NOT bumped by Renovate, NOT bumped on upgrade.
  talos_secrets_contract = "v1.12.6"

  # renovate: datasource=github-releases depName=siderolabs/talos
  talos_version = "v1.12.12" # keep in sync with other clusters
  # renovate: datasource=github-releases depName=kubernetes/kubernetes extractVersion=^v(?<version>.*)$
  kubernetes_version = "1.35.2"

  # Schematic includes: siderolabs/iscsi-tools + siderolabs/util-linux-tools
  # Regenerate at https://factory.talos.dev when extensions change.
  talos_schematic_id = "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"

  # ── OS install disk ────────────────────────────────────────────────────────
  # Discovery: talosctl get disks -n 192.168.1.202 --insecure
  install_disk_selector = { wwid = "eui.0025388391b1e82e" }

  # ── Longhorn data disks ────────────────────────────────────────────────────
  # No dedicated disk yet, so /var/lib/longhorn lives on the OS nvme above. That is
  # why machine.install.wipe is dangerous on this node specifically.
  #
  # An SSD has been bought for this node but is not installed. When it is, it MUST
  # NOT mount at /var/lib/longhorn — that path already holds live replica data, and
  # mounting over it hides the data rather than migrating it. Register the new path
  # as a second Longhorn disk, evict replicas onto it, then retire the OS-disk one.
  #
  # Samsung V-NAND SSD 860 EVO
  longhorn_disks = {
    "192.168.1.202" = {
      device     = "/dev/disk/by-id/wwn-0x5002538ed0beadbb"   # talosctl get disks -n 192.168.1.202
      mountpoint = "/var/mnt/longhorn-ssd"
    }
  }

  # ── Credentials output ─────────────────────────────────────────────────────
  credentials_dir = "${path.root}/../credentials"
}
