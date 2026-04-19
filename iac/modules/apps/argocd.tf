data "sops_file" "argocd" {
  source_file = var.sops_secrets_file
}

# Create the namespace explicitly so the argocd-secret can be provisioned before Helm runs.
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

# Create argocd-secret directly so Helm skips it (configs.secret.createSecret: false).
#
# ESO handoff: once ESO is fully operational, delete this Terraform resource and let
# an ExternalSecret sync argocd-secret from OpenBao instead.
#
# Note: bcrypt() is non-deterministic (random salt each call), so every `terraform apply`
# recomputes the hash and triggers a secret update. To avoid churn, pre-compute the hash
# and store adminPasswordHash in the SOPS file, then reference it directly here.
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
    "admin.password"      = bcrypt(data.sops_file.argocd.data["adminPassword"])
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
