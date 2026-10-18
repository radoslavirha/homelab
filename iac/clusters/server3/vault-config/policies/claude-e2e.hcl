# claude-e2e — the Authentik E2E test user's credentials, and nothing else.
# Read by coding agents through the claude-e2e Kubernetes auth role (docs/identity.md § The E2E
# test user). No list, no metadata, no write: the operator seeds the path with an admin session.
path "secret/data/agents/e2e-claude" {
  capabilities = ["read"]
}
