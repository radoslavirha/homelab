# Applies the ArgoCD self-management Application once.
# After creation, ArgoCD reconciles this Application from git —
# lifecycle.ignore_changes prevents Terraform from overwriting ArgoCD's state.
#
# Set argocd_self_manage_yaml to the contents of the ArgoCD.yaml manifest from
# gitops/clusters/<cluster>/argocd-manifests/ArgoCD.yaml once the gitops
# directory is populated. Leave empty to skip this step during initial setup.
resource "kubectl_manifest" "argocd_self_manage" {
  count = var.argocd_self_manage_yaml != "" ? 1 : 0

  yaml_body         = var.argocd_self_manage_yaml
  server_side_apply = true
  depends_on        = [helm_release.argocd]

  lifecycle {
    ignore_changes = [yaml_body]
  }
}
