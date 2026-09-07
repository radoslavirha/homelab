locals {
  kubeconfig_path  = "${var.credentials_dir}/kubeconfig"
  talosconfig_path = "${var.credentials_dir}/talosconfig"

  # Prefer VIP as the API endpoint for HA clusters; fallback to first controlplane IP.
  api_endpoint = var.cluster_vip != "" ? var.cluster_vip : var.controlplane_ips[0]

  installer_image = "factory.talos.dev/metal-installer/${var.talos_schematic_id}:${var.talos_version}"

  # Per-node Longhorn disk, resolved positionally so the config patches below stay
  # readable. null for a node with no dedicated disk.
  controlplane_longhorn = [for ip in var.controlplane_ips : lookup(var.longhorn_disks, ip, null)]
  worker_longhorn       = [for ip in var.worker_ips : lookup(var.longhorn_disks, ip, null)]
}

# ── 1. Machine secrets (CA, bootstrap token, etc.) ──────────────────────────
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_secrets_contract

  # Second line of defence. Even if talos_secrets_contract is edited by mistake,
  # Terraform will not plan an update against this resource — the provider drops
  # machine_secrets on any update, which on a single-controlplane node means
  # losing the Talos API and etcd at once.
  lifecycle {
    ignore_changes = [talos_version]
  }
}

# ── 2. Client configuration (talosconfig) ───────────────────────────────────
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = concat(var.controlplane_ips, var.worker_ips)
  endpoints            = var.cluster_vip != "" ? [var.cluster_vip] : var.controlplane_ips
}

# ── 3a. Controlplane machine configuration (one per node) ───────────────────
# count-based so each node gets its own config including per-node disk patches.
# The talos provider cannot handle dynamic values in talos_machine_configuration_apply
# config_patches, so per-node patches are inlined here instead.
data "talos_machine_configuration" "controlplane" {
  count = length(var.controlplane_ips)

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${local.api_endpoint}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = compact(concat(
    [
      # Disable default CNI (Flannel) and kube-proxy — Cilium takes both over.
      file("${path.module}/patches/cilium.yaml"),
      yamlencode({
        machine = {
          install = {
            image        = local.installer_image
            diskSelector = var.install_disk_selector
            wipe         = var.install_wipe
          }
        }
      }),
      # Optional: mount dedicated Longhorn disk on nodes that have one.
      local.controlplane_longhorn[count.index] != null ? yamlencode({
        machine = {
          disks = [{
            device     = local.controlplane_longhorn[count.index].device
            partitions = [{ mountpoint = local.controlplane_longhorn[count.index].mountpoint }]
          }]
          kubelet = {
            extraMounts = [{
              destination = local.controlplane_longhorn[count.index].mountpoint
              type        = "bind"
              source      = local.controlplane_longhorn[count.index].mountpoint
              options     = ["bind", "rshared", "rw"]
            }]
          }
        }
      }) : "",
    ],
    # Allow workload pods on the control-plane when there are no dedicated workers.
    length(var.worker_ips) == 0 ? [file("${path.module}/patches/scheduling.yaml")] : []
  ))
}

# ── 3b. Worker machine configuration (one per node) ─────────────────────────
data "talos_machine_configuration" "worker" {
  count = length(var.worker_ips)

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${local.api_endpoint}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = compact([
    file("${path.module}/patches/cilium.yaml"),
    yamlencode({
      machine = {
        install = {
          image        = local.installer_image
          diskSelector = var.install_disk_selector
          wipe         = var.install_wipe
        }
      }
    }),
    local.worker_longhorn[count.index] != null ? yamlencode({
      machine = {
        disks = [{
          device     = local.worker_longhorn[count.index].device
          partitions = [{ mountpoint = local.worker_longhorn[count.index].mountpoint }]
        }]
        kubelet = {
          extraMounts = [{
            destination = local.worker_longhorn[count.index].mountpoint
            type        = "bind"
            source      = local.worker_longhorn[count.index].mountpoint
            options     = ["bind", "rshared", "rw"]
          }]
        }
      }
    }) : "",
  ])
}

# ── 4a. Apply configuration to controlplane nodes ───────────────────────────
resource "talos_machine_configuration_apply" "controlplane" {
  count = length(var.controlplane_ips)

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[count.index].machine_configuration
  node                        = var.controlplane_ips[count.index]
  endpoint                    = var.controlplane_ips[count.index]

  lifecycle {
    replace_triggered_by = [talos_machine_secrets.this]
  }
}

# ── 4b. Apply configuration to worker nodes ──────────────────────────────────
resource "talos_machine_configuration_apply" "worker" {
  count = length(var.worker_ips)

  depends_on = [talos_machine_bootstrap.this]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  node                        = var.worker_ips[count.index]
  endpoint                    = var.worker_ips[count.index]

  lifecycle {
    replace_triggered_by = [talos_machine_secrets.this]
  }
}

# ── 5. Bootstrap the cluster (etcd init — runs once on first controlplane) ───
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.controlplane]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controlplane_ips[0]
  endpoint             = var.controlplane_ips[0]
}

# ── 6. Retrieve kubeconfig ───────────────────────────────────────────────────
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controlplane_ips[0]
  endpoint             = var.controlplane_ips[0]
}

# ── 7. Write credentials to disk ────────────────────────────────────────────
# Credentials are written to iac/clusters/<cluster>/credentials/ which is gitignored.
resource "local_sensitive_file" "talosconfig" {
  content              = data.talos_client_configuration.this.talos_config
  filename             = local.talosconfig_path
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "local_sensitive_file" "kubeconfig" {
  depends_on           = [talos_machine_bootstrap.this]
  content              = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename             = local.kubeconfig_path
  file_permission      = "0600"
  directory_permission = "0700"
}
