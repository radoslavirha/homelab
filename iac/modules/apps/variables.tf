variable "kubeconfig_path" {
  type        = string
  description = "Absolute path to the kubeconfig file written by the bootstrap module."
}

variable "argocd_chart_version" {
  type        = string
  description = "Version of the argo-cd Helm chart. Check latest: helm search repo argo/argo-cd --versions"
}

variable "argocd_values" {
  type        = string
  description = "Contents of the ArgoCD Helm values override file. Use file() in the cluster instance."
}

# OpenBao KV v2 path (under the "secret" mount) that holds the ArgoCD admin credential.
# The secret must contain a field named "adminPasswordHash" — a pre-computed bcrypt hash.
# Store with: bao kv put secret/argocd adminPasswordHash='$2a$10$...'
# Generate:   python3 -c "import bcrypt; print(bcrypt.hashpw(b'PASSWORD', bcrypt.gensalt()).decode())"
variable "argocd_vault_secret_path" {
  type        = string
  description = "OpenBao KV v2 path (mount=secret) containing adminPasswordHash for ArgoCD. Use cluster-scoped paths, e.g. server3/argocd."
  default     = "argocd"
}

# Raw YAML of the ArgoCD self-management Application manifest.
# Pass: file("${path.root}/../../../gitops/argocd-manifests/ArgoCD.yaml")
# Leave empty ("") to skip (only if the manifest does not exist yet).
variable "argocd_self_manage_yaml" {
  type        = string
  description = "Raw YAML of the ArgoCD Application that makes ArgoCD manage itself. Empty string skips the resource."
  default     = ""
}
