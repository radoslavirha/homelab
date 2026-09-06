# homelab

Personal Kubernetes homelab — three Talos Linux clusters managed as Infrastructure as Code.

## Clusters

| Cluster | Role | Machine |
|---------|------|----------|
| `server1` | Production workloads | server1 — 32 GB RAM / 6 cores / 500 GB SSD |
| `server2` | Experimentation | server2 — 32 GB RAM / 6 cores / 500 GB SSD |
| `server3` | Platform services — OpenBao, ArgoCD, Authentik | server3 — 16 GB RAM / 4 cores / 256 GB SSD |

## Dependency updates

Renovate (Mend GitHub App) watches every pinned chart, provider, image and CLI version and lists
what has moved on a **Dependency Dashboard** issue. It opens no pull request until an update is
approved there, and never automerges.

Merging is not deploying: `gitops/` changes need a Hard Refresh and Sync in ArgoCD, and `iac/`
changes need `terraform apply`. See [AGENTS.md](AGENTS.md) → "Dependency monitoring (Renovate)".

## Repository structure

```
iac/          Terraform — bootstrap + platform + GitOps bootstrap (ArgoCD install)
gitops/       ArgoCD manifests, Helm values, raw K8s manifests (per cluster)
docs/         Architecture decisions and operational guides
```

See [docs/iac.md](docs/iac.md) for Terraform module usage, bootstrap sequence, and state backend migration.
See [docs/architecture.md](docs/architecture.md) for multi-cluster decisions and the future roadmap.
See [docs/observability.md](docs/observability.md) for the LGTM stack architecture, OTel pipeline, and Grafana datasource correlations.

## Quick start

**→ [docs/quickstart.md](docs/quickstart.md)** — complete ordered runbook for provisioning server3, then server2/server1. All commands in sequence, all secrets in one block per cluster. No background reading required.

## Full reference

```bash
# Bootstrap server3 — also includes vault (OpenBao) and apps (ArgoCD) stages
cd iac/clusters/server3/bootstrap && terraform init && terraform apply -auto-approve
cd iac/clusters/server3/platform  && terraform init && terraform apply -auto-approve
cd iac/clusters/server3/vault     && terraform init && terraform apply -auto-approve
cd iac/clusters/server3/apps      && terraform init && terraform apply -auto-approve

# Apply GitOps Root Apps (two kubectl applies — Bootstrap orders the rest via sync waves)
export KUBECONFIG=iac/clusters/server3/credentials/kubeconfig
kubectl apply -f gitops/argocd-manifests/ArgoCD.yaml
kubectl apply -f gitops/argocd-manifests/Bootstrap.yaml

# Bootstrap server1 / server2 (run in order)
cd iac/clusters/<cluster>/bootstrap && terraform init && terraform apply -auto-approve
cd iac/clusters/<cluster>/platform  && terraform init && terraform apply -auto-approve

# Check cluster health
talosctl health
kubectl get nodes
```
