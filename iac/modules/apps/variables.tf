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

# Path to the SOPS-encrypted YAML file containing the ArgoCD admin password.
# The cluster instance should pass an absolute path, e.g. path.root + "/../secrets/argocd.sops.yaml".
# File must exist at iac/clusters/<cluster>/secrets/argocd.sops.yaml (gitignored).
# See docs/iac.md for the secret layout.
variable "sops_secrets_file" {
  type        = string
  description = "Path to the SOPS-encrypted ArgoCD secrets file."
}

# Raw YAML of the ArgoCD self-management Application manifest.
# After the gitops/ directory is populated, pass the file contents:
#   file("<path.root>/../../../../gitops/clusters/<cluster>/argocd-manifests/ArgoCD.yaml")
# Leave empty ("") to skip creating the self-management resource (e.g. during initial setup).
variable "argocd_self_manage_yaml" {
  type        = string
  description = "Raw YAML of the ArgoCD Application that makes ArgoCD manage itself. Empty string skips the resource."
  default     = ""
}
