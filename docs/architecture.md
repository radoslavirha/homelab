# Architecture

Multi-cluster Kubernetes homelab: three Talos Linux nodes managed with a shared Terraform module library and a single GitOps repo.

## Cluster roles

| Cluster | Machine | Role |
|---------|---------|------|
| `server1` | server1 — 32 GB RAM / 6 cores / 500 GB SSD | Production workloads + full monitoring stack |
| `server2` | server2 — 32 GB RAM / 6 cores / 500 GB SSD | Experimentation, staging |
| `server3` | server3 — 16 GB RAM / 4 cores / 256 GB SSD | Platform services — MinIO, OpenBao, ArgoCD (manages all clusters) |

## Technology stack

| Component | Managed by | Notes |
|-----------|-----------|-------|
| Talos Linux | Terraform bootstrap | All three clusters |
| Cilium CNI | Terraform platform | kube-proxy replacement, Gateway API controller |
| Gateway API CRDs | Terraform platform | Installed before Cilium |
| Longhorn | Terraform platform | Single-replica on server3; multi-replica on server1 |
| OpenBao | Terraform secrets (server3 only) | Central secrets backend for all clusters |
| ArgoCD | Terraform apps (server3 only) | Installed on server3; manages workloads on all three clusters via registered external clusters |
| External Secrets Operator | ArgoCD | Per cluster; ClusterSecretStore points to server3 OpenBao |
| Traefik | ArgoCD (server3) | hostNetwork bare-metal ingress; Gateway API provider; externalIPs |
| ExternalDNS | ArgoCD (server3) | Unifi webhook; sources: gateway-httproute, traefik-proxy, crd |
| Headlamp | ArgoCD (server3) | Kubernetes dashboard UI; HTTPRoute headlamp.server3.home |
| Hubble UI | ArgoCD (server3) | Cilium network observability UI; HTTPRoute hubble.server3.home |
| Longhorn UI | ArgoCD (server3) | Longhorn storage dashboard; HTTPRoute longhorn.server3.home |
| MinIO | ArgoCD (server3) | S3-compatible storage for Terraform state and Longhorn backups |
| All other apps | ArgoCD | See gitops/argocd-manifests/<cluster>/ |

## Multi-cluster design decisions

### Why Terraform for bootstrap + platform + ArgoCD install (server3 only)?

These components must exist before ArgoCD can function. Installing them with ArgoCD creates a chicken-and-egg dependency. Terraform manages them directly; ArgoCD self-manages its own Helm release after first install (via the self-management Application).

ArgoCD is installed only on the server3 cluster and manages all three clusters. The server1 and server2 clusters do not run their own ArgoCD instance.

### Why OpenBao on the server3 cluster, managed by Terraform?

OpenBao is a prerequisite for External Secrets Operator across all clusters. If ArgoCD managed OpenBao, ESO couldn't sync secrets needed to start ArgoCD's own apps — a circular dependency. Managing it via Terraform (same as Longhorn) solves this. The server3 cluster is the trust anchor.

### Why Longhorn on the server3 cluster?

Longhorn provides durable PersistentVolumes for OpenBao. With `backupTarget` pointing to MinIO (same cluster), Longhorn snapshots give automatic OpenBao backups with no external dependency. The overhead (≈500 MB RAM, single replica) is acceptable on 32 GB RAM.

### Why not ArgoCD hub-spoke now?

Hub-spoke is the design from day one: ArgoCD runs only on the server3 cluster and manages workloads on all three clusters via registered external clusters.

Bootstrap order:
1. Server3 cluster is provisioned and ArgoCD is installed via Terraform
2. Server1 and server2 clusters are provisioned (bootstrap + platform only via Terraform)
3. Their kubeconfigs are registered in server3 ArgoCD
4. ArgoCD deploys all apps to server1 and server2 via ApplicationSets

### Why a single GitOps repo for all clusters?

With one operator (you), there is no access control requirement that mandates separation. A single `gitops/` directory with `clusters/<name>/` subdirectories reduces cross-repo coordination friction and makes it easy to share charts and values. ArgoCD Applications scope themselves to the correct subdirectory via `path:`.

### IaC vs GitOps separation (two top-level directories in this repo)

Terraform code (IaC) and ArgoCD content (GitOps) are separated at the directory level, not at the repo level. This gives clean separation of concerns while keeping related content co-located. ArgoCD is scoped to `gitops/` via `path:` in Application manifests and never syncs anything from `iac/`.

### Why no Terraform remote backend initially?

MinIO is the intended S3-compatible backend for Terraform state. But MinIO itself is deployed by ArgoCD on the server3 cluster. This chicken-and-egg means the server3 cluster's TF state starts local and is migrated to MinIO after MinIO becomes operational. All subsequent clusters (server1) use MinIO from the start.

## Bootstrap sequence

```
┌─────────────────────────────────────────────────────────────────────────┐
│ SERVER3 CLUSTER                                                         │
│                                                                         │
│  1. terraform bootstrap  → Talos cluster + credentials                  │
│  2. terraform platform   → Cilium + Longhorn + Gateway API              │
│  3. terraform vault      → OpenBao                                      │
│     [manual: OpenBao init ceremony, unseal, KV path setup]              │
│  4. terraform apps       → ArgoCD                                       │
│     [manual: create sops-age-key Secret in argocd namespace]            │
│  5. ArgoCD GitOps        → ESO, MinIO, Traefik, ...                    │
│     [manual: terraform init -migrate-state for all server3 modules]     │
│  6. Register server1 + server2 kubeconfigs in server3 ArgoCD            │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ SERVER1 / SERVER2 CLUSTER                                               │
│                                                                         │
│  1. terraform bootstrap  → Talos cluster + credentials                  │
│  2. terraform platform   → Cilium + Longhorn + Gateway API              │
│     (no apps stage — ArgoCD on server3 manages this cluster)            │
│  3. Register kubeconfig in server3 ArgoCD                               │
│  4. server3 ArgoCD GitOps → ESO (→ server3 OpenBao), all apps          │
└─────────────────────────────────────────────────────────────────────────┘
```

## ArgoCD hub-spoke

ArgoCD runs only on the server3 cluster and manages workloads on all three clusters. There are no per-cluster ArgoCD instances.

- server3 ArgoCD manages `server3`, `server1`, and `server2` via registered external clusters
- `destination.server` in Application manifests selects which cluster each app deploys to
- ApplicationSets can template apps across clusters
- Destroying/rebuilding server1 or server2 does not affect GitOps state (it lives on server3)

Post-bootstrap steps for each new cluster:
1. Register its kubeconfig in server3 ArgoCD (`argocd cluster add`)
2. Apply the cluster's ApplicationSets / Application manifests from `gitops/`

## Secret management

Secrets flow: OpenBao (server3 cluster) → ESO ClusterSecretStore → Kubernetes Secrets.

- OpenBao KV path layout: `secret/<cluster>/<app>/<key>`
- Each cluster has an ESO `ClusterSecretStore` pointed at server3 OpenBao (HTTPS over LAN)
- The only SOPS-encrypted secrets in this repo are per-cluster `argocd.sops.yaml` (Terraform consumption)

OpenBao initialization is a manual ceremony performed once after the server3 secrets stage.
Steps are documented at [docs/secrets.md](docs/secrets.md) (to be created).
