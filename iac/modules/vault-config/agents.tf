# ── Kubernetes auth — agent roles ────────────────────────────────────────────
# Coding agents on the operator's machine log in to OpenBao with a short-lived ServiceAccount
# token minted through the admin kubeconfig they already hold (`kubectl create token`), instead
# of a hand-minted OpenBao token kept on disk. Nothing long-lived is stored anywhere: the
# ServiceAccount token and the OpenBao token both expire with the run.
#
# The ServiceAccount carries no RBAC in its cluster, so its token is useful only as this login,
# and the policy reads one KV path. Reusing the admin kubeconfig adds no exposure: whoever holds
# it can already mint ESO's ServiceAccount token and read everything ESO can.
#
# Same split as the provisioner roles (kubernetes.tf): only the ROLE and its policy live here.
# `mount` names a CLI-created `kubernetes-<cluster>` mount as a plain string, never a reference.

resource "vault_policy" "agent" {
  for_each = var.kubernetes_agent_roles

  name   = each.key
  policy = each.value.policy
}

resource "vault_kubernetes_auth_backend_role" "agent" {
  for_each = var.kubernetes_agent_roles

  backend   = each.value.mount
  role_name = each.key

  bound_service_account_names      = [each.value.service_account_name]
  bound_service_account_namespaces = [each.value.namespace]

  token_policies = [vault_policy.agent[each.key].name]
  # One run's worth, and no renewal past it: the next run logs in again.
  token_ttl     = each.value.token_ttl
  token_max_ttl = each.value.token_ttl
}
