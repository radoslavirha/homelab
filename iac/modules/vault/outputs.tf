output "openbao_version" {
  description = "Deployed OpenBao chart version."
  value       = helm_release.openbao.version
}
