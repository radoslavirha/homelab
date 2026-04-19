# Documentation Section Map

Maps each documentation section to its authoritative source so the agent knows exactly what to verify after a change.

## README.md

| Section | Source of Truth |
|---------|----------------|
| Cluster table (`Cluster / Role / Machine`) | Machine specs are fixed hardware facts; roles come from `docs/architecture.md` cluster roles table |
| Repository structure tree (`iac/`, `gitops/`, `docs/`) | Actual top-level workspace layout |
| Quick-reference bootstrap commands | `docs/iac.md` bootstrap sequences |

## AGENTS.md

| Section | Source of Truth |
|---------|----------------|
| Repository layout tree (```block at top```) | Actual workspace: `iac/modules/`, `iac/clusters/`, `gitops/` |
| "Two installation paths" — Terraform-managed version table | Each component's `iac/clusters/<cluster>/<stage>/main.tf` — the `module {}` call variable names |
| "Two installation paths" — ArgoCD-managed description | `gitops/argocd-manifests/server3/` — which apps live there |
| "Adding a new cluster" — steps | Bootstrap procedure in `docs/iac.md` |
| "Adding a new ArgoCD app" — steps | ArgoCD manifests structure in `gitops/argocd-manifests/` |
| "Credentials" paths | `iac/clusters/<cluster>/credentials/` actual layout |

## docs/architecture.md

| Section | Source of Truth |
|---------|----------------|
| Cluster roles table (`Cluster / Machine / Role`) | Hardware is fixed; role assignments are design decisions |
| Technology stack table (`Component / Managed by / Notes`) | Terraform stages in `iac/` + ArgoCD manifests in `gitops/argocd-manifests/` |
| Bootstrap sequence diagram (ASCII boxes) | `docs/iac.md` bootstrap sequences — must stay in sync |
| "ArgoCD hub-spoke" description | `gitops/argocd-manifests/server3/` — which clusters are registered |
| "Secret management" — OpenBao KV path layout | `docs/iac.md` SOPS section + actual ESO manifests in `gitops/k8s-manifests/` |

## docs/iac.md

| Section | Source of Truth |
|---------|----------------|
| Directory structure tree | Actual workspace layout (run `find iac/ gitops/ -maxdepth 3 -type d`) |
| Bootstrap sequence — Server3 | Actual Terraform stages: `iac/clusters/server3/` subdirectories |
| Bootstrap sequence — Server1/Server2 | Actual Terraform stages: `iac/clusters/<cluster>/` subdirectories |
| Module variable reference — `modules/bootstrap` | `iac/modules/bootstrap/variables.tf` |
| Module variable reference — `modules/platform` | `iac/modules/platform/variables.tf` |
| Module variable reference — `modules/vault` | `iac/modules/vault/variables.tf` |
| Module variable reference — `modules/apps` | `iac/modules/apps/variables.tf` |
| Helm values paths | `iac/clusters/<cluster>/helm-values/` actual files |

## Shared / Cross-Doc Consistency Rules

These values must be identical wherever they appear:

| Fact | Appears in |
|------|-----------|
| Which cluster hosts ArgoCD | `README.md` cluster table, `AGENTS.md` layout, `docs/architecture.md` stack table + hub-spoke section, `docs/iac.md` bootstrap |
| Which cluster has `vault` stage | `AGENTS.md` version table + layout, `docs/architecture.md` stack table, `docs/iac.md` structure + bootstrap |
| Which cluster has `apps` stage | Same as vault stage above |
| Cluster count and names | All four docs |
| `gitops/` subdirectory layout | `AGENTS.md` layout tree |
| `iac/modules/` subdirectory list | `AGENTS.md` layout tree, `docs/iac.md` structure tree |
