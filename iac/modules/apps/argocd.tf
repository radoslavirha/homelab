# Read the pre-computed bcrypt hash from OpenBao.
# Requires VAULT_ADDR and VAULT_TOKEN (or ~/.vault-token) to be set.
data "vault_kv_secret_v2" "argocd" {
  mount = "secret"
  name  = var.argocd_vault_secret_path
}

# Create the namespace explicitly so the argocd-secret can be provisioned before Helm runs.
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

# Create argocd-secret directly so Helm skips it (configs.secret.createSecret: false).
# ArgoCD requires admin.password to be a bcrypt hash — the hash is stored pre-computed
# in OpenBao to avoid re-hashing (with a new random salt) on every terraform apply.
#
# ESO handoff: once ESO is fully operational, delete this resource and let an
# ExternalSecret sync argocd-secret from OpenBao instead.
resource "kubernetes_secret" "argocd" {
  metadata {
    name      = "argocd-secret"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "argocd-secret"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data = {
    "admin.password"      = data.vault_kv_secret_v2.argocd.data["adminPasswordHash"]
    "admin.passwordMtime" = "2026-04-07T00:00:00Z"
  }
}

resource "helm_release" "argocd" {
  name      = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  wait       = true
  timeout    = 300

  values = [var.argocd_values]

  depends_on = [kubernetes_secret.argocd]
}
