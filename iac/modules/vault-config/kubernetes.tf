# ── Kubernetes auth — provisioner roles ──────────────────────────────────────
# PostSync provisioner Jobs (docs/provisioning.md) log in to OpenBao with their pod's
# ServiceAccount token instead of carrying a hand-minted KV token. See
# docs/superpowers/specs/2026-09-22-provisioner-kubernetes-auth.md.
#
# Only the ROLE is managed here. The `kubernetes-<cluster>` auth MOUNT, its config and the
# `external-secrets` role stay on the CLI (docs/iac.md § 3.c-3.d), for two reasons:
#
#   1. Ordering. ESO must be able to log in before the first ArgoCD Application carrying an
#      ExternalSecret syncs — and this stage runs LAST, after authentik-server3 is Healthy,
#      which itself needs ESO. Managing ESO's mount here would be circular. (Note it is not
#      "before ArgoCD": ArgoCD's own secret comes straight from Terraform via the vault
#      provider — modules/apps/argocd.tf — and needs no ESO at all.)
#   2. State. `token_reviewer_jwt` is a non-expiring system:auth-delegator credential and the
#      provider has no write-only variant for it, so it would sit in plaintext tfstate. The
#      OIDC client secret was deliberately kept out of state with `_wo`; this would undo that.
#
# A provisioner role has neither problem: the Jobs are PostSync hooks that run long after
# everything above, and the role stores no secret. `backend` is therefore a plain string
# naming the CLI-created mount, not a reference — no cross-stage dependency either way.
#
# The `<cluster>-provisioner` POLICY is also left on the CLI: it already exists, is unchanged
# by this work, and importing it would buy nothing.

resource "vault_kubernetes_auth_backend_role" "provisioner" {
  for_each = var.kubernetes_provisioner_roles

  backend   = each.key
  role_name = var.kubernetes_provisioner_role_name

  bound_service_account_names      = [each.value.service_account_name]
  bound_service_account_namespaces = each.value.namespaces

  token_policies = each.value.token_policies
  # Mirrors the external-secrets role on the same mount. A Job runs in seconds, so nothing
  # renews and nothing needs to — the login is the renewal.
  token_ttl = each.value.token_ttl
}
