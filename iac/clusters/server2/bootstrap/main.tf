# ── Server2 cluster — bootstrap ──────────────────────────────────────────────
# Provisions the Talos Linux cluster and writes credentials to ../credentials/.
# Run first before platform or apps.
#
# Usage:
#   cd iac/clusters/server2/bootstrap
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    talos = { source = "siderolabs/talos" }
  }

  # TODO: migrate to MinIO S3 backend once the server3 cluster is running.
  # backend "s3" {
  #   bucket                      = "terraform-state"
  #   key                         = "clusters/server2/bootstrap/terraform.tfstate"
  #   endpoint                    = "https://minio.server3.home"
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
  cluster_name = "server2"

  # ── Node network ─────────────────────────────────────────────────────────
  controlplane_ips = ["192.168.1.201"]
  worker_ips       = []
  # cluster_vip    = ""    # set when adding a second controlplane for HA

  # ── Talos ──────────────────────────────────────────────────────────────────
  talos_version      = "v1.12.6"
  kubernetes_version = "1.35.2"

  # Schematic includes: siderolabs/iscsi-tools + siderolabs/util-linux-tools
  # Regenerate at https://factory.talos.dev when extensions change.
  talos_schematic_id = "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"

  # ── OS install disk ────────────────────────────────────────────────────────
  # Discovery: talosctl get disks -n 192.168.1.201 --insecure
  # SK hynix BC501 HFM256GDJTNG-8310A (ND88N747210509206)
  install_disk_selector = { wwid = "eui.ace42e8170382260" }

  # ── Longhorn data disks ────────────────────────────────────────────────────
  # KINGSTON SHFS37A — dedicated SATA SSD mounted at /var/lib/longhorn
  longhorn_disks = {
    "192.168.1.201" = "/dev/disk/by-id/wwn-0x50026b725b05e218"
  }

  # ── Credentials output ─────────────────────────────────────────────────────
  credentials_dir = "${path.root}/../credentials"
}
