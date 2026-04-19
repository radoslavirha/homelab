# ── Cluster identity ────────────────────────────────────────────────────────
variable "cluster_name" {
  type        = string
  description = "Name of the Talos / Kubernetes cluster."
}

# ── Node network ────────────────────────────────────────────────────────────
variable "controlplane_ips" {
  type        = list(string)
  description = "IP addresses of control-plane nodes. First IP is used for bootstrap and as kubeconfig endpoint."

  validation {
    condition = (
      length(var.controlplane_ips) > 0 &&
      length(var.controlplane_ips) == length(distinct(var.controlplane_ips)) &&
      alltrue([for ip in var.controlplane_ips : trimspace(ip) != ""])
    )
    error_message = "controlplane_ips must contain at least one unique, non-empty IP address."
  }
}

variable "worker_ips" {
  type        = list(string)
  description = "IP addresses of worker nodes. Leave empty for a single-node cluster."
  default     = []
}

variable "cluster_vip" {
  type        = string
  description = "Virtual IP for the cluster API endpoint (required for HA, optional for single-node). Leave empty to use the first controlplane IP."
  default     = ""
}

# ── Talos ────────────────────────────────────────────────────────────────────
variable "talos_version" {
  type        = string
  description = "Talos Linux version to target."
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version to target."
}

# Talos Image Factory schematic ID.
# Current base schematic includes: siderolabs/iscsi-tools + siderolabs/util-linux-tools
# (required for Longhorn iSCSI support).
# Generate a new schematic at: https://factory.talos.dev
variable "talos_schematic_id" {
  type        = string
  description = "Talos Image Factory schematic ID (controls which system extensions are baked in)."
}

# ── OS install disk ──────────────────────────────────────────────────────────
# Selector passed to machine.install.diskSelector in the Talos machine config.
# Keys map directly to Talos diskSelector fields (type, model, wwid, etc.).
variable "install_disk_selector" {
  type        = map(string)
  description = "Talos diskSelector for the OS install disk."
  default     = { type = "nvme" }
  # Examples:
  # install_disk_selector = { type = "sata" }
  # install_disk_selector = { wwid = "naa.50026b725b05e218" }
}

# ── Longhorn data disks ──────────────────────────────────────────────────────
# Optional: configure a dedicated disk for Longhorn storage on specific nodes.
# If a node IP is not listed here, Longhorn stores data on the OS disk.
variable "longhorn_disks" {
  type        = map(string)
  description = "Per-node disk path for Longhorn storage. Key = node IP, value = disk device path."
  default     = {}
  # Example:
  # longhorn_disks = {
  #   "192.168.1.201" = "/dev/disk/by-id/wwn-0x50026b725b05e218"
  # }
}

# ── Credentials output directory ─────────────────────────────────────────────
variable "credentials_dir" {
  type        = string
  description = "Directory where kubeconfig and talosconfig are written. Pass an absolute path, e.g. pass path.root + '/../credentials' from the cluster instance."
}
