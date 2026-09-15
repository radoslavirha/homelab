output "oidc_mount_accessor" {
  description = "Accessor of the OIDC auth mount, for any further group aliases."
  value       = vault_jwt_auth_backend.oidc.accessor
}
