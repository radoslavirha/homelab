---
description: "Rules for the authentik-blueprints chart and its values matrix"
applyTo: "gitops/helm-charts/authentik-blueprints/**,gitops/helm-values/server3/authentik-blueprints.yaml"
---

# Authentik blueprints

Applications, providers, role groups, policy bindings and outposts are **generated** from the matrix in
`gitops/helm-values/server3/authentik-blueprints.yaml` — never clicked together in the UI. For any
add/change/remove, follow the `authentik-blueprints` skill: it carries the checklist and the
verification loop. Model and token claims: `docs/identity.md`.

Traps that apply to any edit here:

- **Roles are a ladder, membership flows upward.** `{ name: admin, inherits: editor }` makes admin the
  CHILD of editor in Authentik, so an admin-only member gets all three roles in the claim.
- **`kind`** says what an entry is: `api` (default; a human's browser logs in), `client` (a human drives
  it and it calls other APIs — Postman), `device` (a machine: confidential, client_credentials, a
  blueprint-declared service account), `proxy` (a UI with no login of its own, forward-auth through the
  `homelab-proxy-<cluster>` outpost). `client` and `device` carry `accesses`, resolved within one
  environment.
- **Blueprints do not prune.** Removing an entry or a role stops managing its objects; groups,
  members, bindings and live provider credentials stay. Removal is two commits — see the skill.
- **`onboarding` and `hardening` are separate ConfigMap keys** on purpose: each key is its own
  BlueprintInstance, so a failure in one cannot take the others down. The cost is that `!KeyOf` does
  not cross them.
- **Two hardening lines decide whether anyone can log in at all:** the order-15 deny stage must keep
  at least one policy bound (with none it runs unconditionally), and the MFA chooser must not be empty
  (`CONFIGURATION_ERROR` fails the stage for everyone).
- **`helm unittest` cannot see** a bad model path, a field a serializer rejects, or an `!Find` that does
  not resolve. Dry-run through Authentik's `Importer.validate()` before pushing
  (`docs/identity.md` § The login surface).
- **Hardening updates objects upstream also manages**, so an Authentik upgrade can revert them with
  nothing failing. Run the post-upgrade check in `docs/identity.md` after every upgrade.
- A ConfigMap that grows past the annotation size ceiling is a template problem (comments duplicated
  per loop iteration), not an ArgoCD one. Fix the template; do not switch the sync strategy.
