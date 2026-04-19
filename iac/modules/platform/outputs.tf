output "cilium_version" {
  description = "Deployed Cilium chart version."
  value       = helm_release.cilium.version
}

output "longhorn_version" {
  description = "Deployed Longhorn chart version, or empty string if Longhorn is disabled."
  value       = try(helm_release.longhorn[0].version, "")
}
