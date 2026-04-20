# homelab

Personal Kubernetes homelab — three Talos Linux clusters managed as Infrastructure as Code.

## Clusters

| Cluster | Role | Machine |
|---------|------|----------|
| `server1` | Production workloads | server1 — 32 GB RAM / 6 cores / 500 GB SSD |
| `server2` | Experimentation | server2 — 32 GB RAM / 6 cores / 500 GB SSD |
| `server3` | Platform services — MinIO, OpenBao, ArgoCD | server3 — 16 GB RAM / 4 cores / 256 GB SSD |

## Repository structure

```
iac/          Terraform — bootstrap + platform + GitOps bootstrap (ArgoCD install)
gitops/       ArgoCD manifests, Helm values, raw K8s manifests (per cluster)
docs/         Architecture decisions and operational guides
```

See [docs/iac.md](docs/iac.md) for Terraform module usage, bootstrap sequence, and state backend migration.
See [docs/architecture.md](docs/architecture.md) for multi-cluster decisions and the future roadmap.

## Quick reference

```bash
# Bootstrap server3 — also includes vault (OpenBao) and apps (ArgoCD) stages
cd iac/clusters/server3/bootstrap && terraform init && terraform apply -auto-approve
cd iac/clusters/server3/platform  && terraform init && terraform apply -auto-approve
cd iac/clusters/server3/vault     && terraform init && terraform apply -auto-approve
cd iac/clusters/server3/apps      && terraform init && terraform apply -auto-approve

# Bootstrap server1 / server2 (run in order)
cd iac/clusters/<cluster>/bootstrap && terraform init && terraform apply -auto-approve
cd iac/clusters/<cluster>/platform  && terraform init && terraform apply -auto-approve

# Check cluster health
talosctl health
kubectl get nodes
```
