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
| Clusters table | `docs/architecture.md` cluster roles table |
| Commands, Access | `iac/clusters/<cluster>/credentials/` layout; how ArgoCD is actually driven |
| Task index | the skills in `.apm/skills/` and the docs it links |
| "Adding a third-party app" / "Adding a cluster" checklists | `gitops/argocd-manifests/` structure; bootstrap procedure in `docs/iac.md` |
| Terminology | Terraform stages under `iac/clusters/<cluster>/`; ArgoCD stages under `gitops/argocd-manifests/apps/` |

Version locations: the `upgrade-components` skill (`.apm/skills/upgrade-components/SKILL.md`), sourced
from each `iac/clusters/<cluster>/<stage>/main.tf`.

## docs/architecture.md

| Section | Source of Truth |
|---------|----------------|
| Cluster roles table (`Cluster / Machine / Role`) | Hardware is fixed; role assignments are design decisions |
| Technology stack table (`Component / Purpose / Clusters / Managed by / Artifact Hub / Local values / Upstream values.yaml`) | Terraform stages in `iac/` + ArgoCD manifests in `gitops/argocd-manifests/`; local values files in `iac/clusters/` (Terraform-managed) and `gitops/helm-values/` (ArgoCD-managed); upstream links point to chart repo `main` branch |
| Bootstrap sequence diagram (ASCII boxes) | `docs/iac.md` bootstrap sequences — must stay in sync |
| "ArgoCD hub-spoke" description | `gitops/argocd-manifests/server3/` — which clusters are registered |
| "Secret management" — OpenBao KV path layout | `docs/secrets.md` + actual ESO manifests in `gitops/k8s-manifests/` |

## docs/iac.md

| Section | Source of Truth |
|---------|----------------|
| Directory structure tree | Actual workspace layout (run `find iac/ gitops/ -maxdepth 3 -type d`) |
| Bootstrap sequence — Server3 | Actual Terraform stages: `iac/clusters/server3/` subdirectories |
| Bootstrap sequence — Server1/Server2 | Actual Terraform stages: `iac/clusters/<cluster>/` subdirectories |
| Bootstrap step 3.f "Seed initial KV secrets" | Every IoT app deployed on server1 must have its `bao kv put` command listed here. Source of truth: `docs/provisioning.md` + `gitops/argocd-manifests/apps/iot/` |
| Module variable reference — `modules/bootstrap` | `iac/modules/bootstrap/variables.tf` |
| Module variable reference — `modules/platform` | `iac/modules/platform/variables.tf` |
| Module variable reference — `modules/vault` | `iac/modules/vault/variables.tf` |
| Module variable reference — `modules/apps` | `iac/modules/apps/variables.tf` |
| Helm values paths | `iac/clusters/<cluster>/helm-values/` actual files |

## docs/provisioning.md

| Section | Source of Truth |
|---------|----------------|
| "Credential bootstrapping" blocks (one per datastore) | Must match the corresponding `bao kv put` commands in `docs/iac.md` step 3.f |
| "Per-app token provisioning" PostSync Job examples | `gitops/k8s-manifests/<cluster>/<datastore>/provisioner-*.yaml` actual files |
| "Provisioner OpenBao token setup" | Must match the `bao policy write <cluster>-provisioner` + `bao token create` commands in `docs/iac.md` step 3.e |

## Shared / Cross-Doc Consistency Rules

These values must be identical wherever they appear:

| Fact | Appears in |
|------|-----------|
| Which cluster hosts ArgoCD | `README.md` cluster table, `AGENTS.md` clusters table, `docs/architecture.md` stack table + hub-spoke section, `docs/iac.md` bootstrap |
| Which cluster has `vault` stage | `upgrade-components` version table, `docs/architecture.md` stack table, `docs/iac.md` structure + bootstrap |
| Which cluster has `apps` stage | Same as vault stage above |
| Cluster count and names | All four docs |
| `iac/modules/` subdirectory list | `docs/iac.md` structure tree |
