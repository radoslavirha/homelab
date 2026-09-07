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
# Two versions, deliberately separate. They are NOT the same thing and must never
# be wired to one variable again — doing so makes every OS upgrade rewrite the
# input to the cluster's PKI resource.
#
# talos_secrets_contract  the version contract for SECRET GENERATION. Frozen at
#                         whatever the cluster was bootstrapped with. Feeds
#                         talos_machine_secrets and nothing else. Never bump it:
#                         provider v0.11.0-beta.2 marks every CA, the cluster
#                         secret and both tokens unknown on update and then never
#                         writes machine_secrets back, so a change drops them.
# talos_version           the OS version actually running. Feeds the installer
#                         image. Safe to bump; Renovate manages it.
variable "talos_secrets_contract" {
  type        = string
  description = "Talos version contract used to GENERATE machine secrets. Frozen at the bootstrap value — never bump this to upgrade Talos, use talos_version."
}

variable "talos_version" {
  type        = string
  description = "Talos Linux version to target (installer image)."
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

# ── OS install behaviour ─────────────────────────────────────────────────────
# machine.install.wipe tells the installer to wipe the target disk. Talos applies
# .machine.install "during install/upgrade" -- it is NOT dormant until a manual
# reinstall, so this fires on an upgrade, a node replacement or a recovery too.
#
# A wipe takes STATE and EPHEMERAL on the install disk: etcd, the machine identity
# and the image cache, on every node. On server3 it also takes /var/lib/longhorn,
# which has no dedicated disk yet.
#
# Default false, deliberately. Wiping only matters when installing onto a disk that
# already holds something; on a genuinely empty disk it changes nothing. Set it true
# explicitly, for one apply, when intentionally reprovisioning a node from scratch.
variable "install_wipe" {
  type        = bool
  description = "Wipe the install disk during install/upgrade. Leave false on any node holding data you want to keep; set true only for a deliberate clean reprovision."
  default     = false
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
#
# mountpoint defaults to /var/lib/longhorn, which is correct only for a disk that
# is EMPTY at bootstrap — that path becomes Longhorn's default data directory.
# Adding a disk to a node that already holds replica data at /var/lib/longhorn
# must use a different mountpoint: mounting over the path hides the existing data
# instead of migrating it. In that case register the new path as a SECOND Longhorn
# disk on the node and evict replicas onto it, then retire the old one.
variable "longhorn_disks" {
  type = map(object({
    device     = string
    mountpoint = optional(string, "/var/lib/longhorn")
  }))
  description = "Per-node dedicated disk for Longhorn storage. Key = node IP. mountpoint defaults to /var/lib/longhorn; override it when the node already stores replicas there."
  default     = {}
  # Example:
  # longhorn_disks = {
  #   "192.168.1.201" = { device = "/dev/disk/by-id/wwn-0x50026b725b05e218" }
  #   "192.168.1.202" = { device = "/dev/disk/by-id/...", mountpoint = "/var/mnt/longhorn-ssd" }
  # }
}

# ── Credentials output directory ─────────────────────────────────────────────
variable "credentials_dir" {
  type        = string
  description = "Directory where kubeconfig and talosconfig are written. Pass an absolute path, e.g. pass path.root + '/../credentials' from the cluster instance."
}
