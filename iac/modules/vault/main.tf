# ── OpenBao namespace ────────────────────────────────────────────────────────
# Create the namespace with privileged PodSecurity labels before Helm installs,
# because OpenBao pods require host-path mounts.
resource "null_resource" "openbao_namespace" {
  triggers = {
    kubeconfig = var.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      kubectl --kubeconfig '${var.kubeconfig_path}' create namespace openbao --dry-run=client -o yaml \
        | kubectl --kubeconfig '${var.kubeconfig_path}' apply -f -
      kubectl --kubeconfig '${var.kubeconfig_path}' label namespace openbao \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged \
        --overwrite
    EOT
  }
}

# ── OpenBao ───────────────────────────────────────────────────────────────────
# Central secrets backend (Vault-compatible). Managed by Terraform — not ArgoCD —
# because it is a prerequisite for ESO ClusterSecretStore on all clusters.
#
# After first install, run the init ceremony manually:
#   kubectl exec -n openbao openbao-0 -- bao operator init   # save unseal keys + root token
#   kubectl exec -n openbao openbao-0 -- bao operator unseal  # repeat with 3 of the 5 keys
#   bao login <root-token>
#   bao secrets enable -path=secret kv-v2
resource "helm_release" "openbao" {
  depends_on = [null_resource.openbao_namespace]

  name             = "openbao"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "openbao"
  create_namespace = false

  values = [var.openbao_values]

  wait    = true
  timeout = 300
}
