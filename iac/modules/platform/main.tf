# ── Gateway API CRDs ────────────────────────────────────────────────────────
# Cilium acts as the Gateway API controller. CRDs must be installed BEFORE Cilium
# when gatewayAPI.enabled = true.
# Uses `kubectl apply --server-side` to handle large CRD objects correctly.
#
# Prerequisites: kubectl must be installed and on PATH when running terraform apply.
resource "null_resource" "gateway_api_crds" {
  triggers = {
    version = var.gateway_api_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply --server-side \
        -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v${var.gateway_api_version}/standard-install.yaml \
        --kubeconfig ${abspath(var.kubeconfig_path)}
    EOT
  }
}

# ── Cilium CNI ───────────────────────────────────────────────────────────────
# Installed after Gateway API CRDs so the operator can register GatewayClass on startup.
resource "helm_release" "cilium" {
  depends_on = [null_resource.gateway_api_crds]

  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = var.cilium_version
  namespace        = "kube-system"
  create_namespace = false

  values = var.cilium_values

  # Cilium must be fully ready before Longhorn can reach the API server.
  wait          = true
  wait_for_jobs = true
  timeout       = 300
}

# ── Longhorn distributed storage ─────────────────────────────────────────────
# Controlled by var.enable_longhorn. Set false when using local-path-provisioner
# or another CSI driver.

# Longhorn requires privileged pods (hostPath volumes + privileged containers).
# Create the namespace with the required PodSecurity labels before Helm installs,
# so the admission controller does not block the longhorn-manager DaemonSet.
resource "null_resource" "longhorn_namespace" {
  count = var.enable_longhorn ? 1 : 0

  depends_on = [helm_release.cilium]

  triggers = {
    kubeconfig = var.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      kubectl --kubeconfig '${var.kubeconfig_path}' create namespace longhorn-system --dry-run=client -o yaml \
        | kubectl --kubeconfig '${var.kubeconfig_path}' apply -f -
      kubectl --kubeconfig '${var.kubeconfig_path}' label namespace longhorn-system \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged \
        --overwrite
    EOT
  }
}

resource "helm_release" "longhorn" {
  count = var.enable_longhorn ? 1 : 0

  depends_on = [null_resource.longhorn_namespace]

  name             = "longhorn"
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = var.longhorn_version
  namespace        = "longhorn-system"
  create_namespace = true

  values = var.longhorn_values

  wait    = true
  timeout = 600
}

# Longhorn requires deleting-confirmation-flag = true before uninstall.
# This null_resource depends on helm_release.longhorn so on destroy Terraform
# runs it first (setting the flag) and only then destroys the Helm release.
resource "null_resource" "longhorn_uninstall_flag" {
  count = var.enable_longhorn ? 1 : 0

  depends_on = [helm_release.longhorn]

  triggers = {
    kubeconfig = var.kubeconfig_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      kubectl --kubeconfig '${self.triggers.kubeconfig}' \
        -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \
        --type=merge -p '{"value":"true"}'
    EOT
  }
}

