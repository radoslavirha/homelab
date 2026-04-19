variable "kubeconfig_path" {
  type        = string
  description = "Absolute path to the kubeconfig file written by the bootstrap module."
}

# ── Component versions ───────────────────────────────────────────────────────
variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version."
}

variable "longhorn_version" {
  type        = string
  description = "Longhorn Helm chart version."
}

variable "gateway_api_version" {
  type        = string
  description = "Gateway API CRD release tag (without leading 'v'). See https://github.com/kubernetes-sigs/gateway-api/releases"
}

# ── Helm values content ───────────────────────────────────────────────────────
variable "cilium_values" {
  type        = string
  description = "Contents of the Cilium Helm values override file. Use file() in the cluster instance."
}

variable "longhorn_values" {
  type        = string
  description = "Contents of the Longhorn Helm values override file. Use file() in the cluster instance."
  default     = ""
}

# ── Feature flags ─────────────────────────────────────────────────────────────
variable "enable_longhorn" {
  type        = bool
  description = "Whether to install Longhorn distributed storage. Set false when using local-path-provisioner or another CSI."
  default     = true
}

