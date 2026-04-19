variable "kubeconfig_path" {
  type        = string
  description = "Absolute path to the kubeconfig file written by the bootstrap module."
}

# ── Component versions ───────────────────────────────────────────────────────
variable "openbao_version" {
  type        = string
  description = "OpenBao Helm chart version. Check latest: helm search repo openbao/openbao --versions"
}

# ── Helm values content ──────────────────────────────────────────────────────
variable "openbao_values" {
  type        = string
  description = "Contents of the OpenBao Helm values override file. Use file() in the cluster instance."
}
