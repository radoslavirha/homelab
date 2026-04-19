output "kubeconfig_path" {
  description = "Absolute path to the generated kubeconfig file."
  value       = abspath("${var.credentials_dir}/kubeconfig")
}

output "talosconfig_path" {
  description = "Absolute path to the generated talosconfig file."
  value       = abspath("${var.credentials_dir}/talosconfig")
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = "https://${local.api_endpoint}:6443"
}

output "controlplane_nodes" {
  description = "Control-plane node IPs."
  value       = var.controlplane_ips
}

output "worker_nodes" {
  description = "Worker node IPs."
  value       = var.worker_ips
}
