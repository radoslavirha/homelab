---
description: "Terraform rules for iac/: module/instance split, Renovate annotations, Talos and OpenBao traps"
applyTo: "iac/**"
---

# Terraform (`iac/`)

## Module + cluster instance

- `iac/modules/<module>/` holds reusable logic; `iac/clusters/<cluster>/<stage>/` calls it with
  cluster values. **Never put a provider configuration inside a module** — only in cluster instances.
- After changing a module, validate every instance that calls it, not just the one you are working in:
  `grep -rl 'modules/<module>' iac/clusters` then `terraform validate` in each.
- State is local files. The `backend "s3"` blocks are commented out and stay that way: MinIO was never
  deployed and is not the plan.
- Provider pins live in `iac/modules/<module>/versions.tf`. `clusters/server3/apps/main.tf` duplicates
  the helm pin; keep both in step. `modules/vault-config` pins vault `5.11.0` while `modules/apps` stays
  on `~> 4.0` on purpose: separate roots and lock files, and 5.x has the ephemeral KV read.

## Versions and Renovate

- Every version variable needs a `# renovate:` comment annotation **directly above it**. A variable
  without one is invisible to Renovate, which looks exactly like being up to date. Example:
  `iac/clusters/server1/platform/main.tf`.
- A merged version bump here is a string change and nothing else. It deploys only on
  `terraform apply` in that cluster's stage. Full procedure: the `upgrade-components` skill.

## Talos

- **`talos_version` is not installed by `terraform apply`.** It feeds only `machine.install.image`,
  read at install time. Upgrading a running node is out-of-band (`talosctl upgrade`, ask first) — see
  the `upgrade-components` skill.
- **Never bump `talos_secrets_contract`** to move the OS version. It exists so the OS version and the
  PKI generation contract cannot move together, and it is protected by `ignore_changes`.
- **Machine-config applies never reboot a node.** Both `talos_machine_configuration_apply` resources
  use `apply_mode = "staged_if_needing_reboot"`, so a change that needs a reboot waits for the next one.
  After an apply, check the node before believing the change is live.
- **A reboot of server3 reseals OpenBao.** It needs the unseal keys by hand before ESO works anywhere.
- **`apiserver_oidc`** (typed, optional, null by default) makes a kube-apiserver trust Headlamp's
  Authentik issuer. Applying it restarts kube-apiserver (about a minute of refused connections), not the
  node. Do not verify apiserver flags from the mirror pod object; it stays stale on Talos. Runbook:
  `docs/identity.md` § Headlamp.

## OpenBao

- Deployed by `iac/clusters/server3/vault/`. The init ceremony is manual — see the header of
  `iac/clusters/server3/vault/main.tf`.
- `iac/clusters/server3/vault-config/` (module `iac/modules/vault-config/`) holds OpenBao's own
  configuration: OIDC login via Authentik, plus Kubernetes auth roles for provisioner Jobs and coding
  agents (roles only, on CLI-made mounts). It runs **last** on a fresh server3, after GitOps
  bootstrap. Nothing that must exist before ArgoCD belongs in it without its own toggle.
- The older auth config is still hand-made (`docs/iac.md` step 3): ESO's `kubernetes-*` mounts,
  `read-secrets`, the provisioner policies, userpass. Bring it under Terraform with `terraform import`,
  **never by recreating a live mount** — a recreated `kubernetes-*` mount breaks every ExternalSecret on
  that cluster.
- Keep userpass and the root token. Authentik's secrets come from OpenBao, so OpenBao must stay
  administrable without Authentik.

## ArgoCD install

`gitops/argocd-manifests/ArgoCD.yaml` is applied by the `apps` stage with `ignore_changes = [yaml_body]`,
so `terraform apply` never updates it after the first run. Changes to it go out with
`kubectl -n argocd apply -f` by hand.
