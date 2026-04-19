# Architecture

Multi-cluster Kubernetes homelab: three Talos Linux nodes managed with a shared Terraform module library and a single GitOps repo.

## Cluster roles

| Cluster | Machine | Role |
|---------|---------|------|
| `server1` | server1 — 32 GB RAM / 6 cores / 500 GB SSD | Production workloads + full monitoring stack |
| `server2` | server2 — 32 GB RAM / 6 cores / 500 GB SSD | Experimentation, staging |
| `server3` | server3 — 16 GB RAM / 4 cores / 256 GB SSD | Platform services — MinIO, OpenBao, ArgoCD (manages all clusters) |

## Technology stack

| Component | Purpose | Clusters | Managed by | Artifact Hub | Local values | Upstream `values.yaml` |
|-----------|---------|:--------:|------------|:------------:|-------------|------------------------|
| [Talos Linux](https://www.talos.dev/) | Immutable Kubernetes OS | all | Terraform `bootstrap` | — | — | — |
| [Cilium](https://docs.cilium.io/) | eBPF CNI, kube-proxy replacement, Hubble, Gateway API controller | all | Terraform `platform` | [cilium](https://artifacthub.io/packages/helm/cilium/cilium) | [shared](../iac/clusters/helm-values/cilium.yaml) · [server1](../iac/clusters/server1/helm-values/cilium.yaml) · [server2](../iac/clusters/server2/helm-values/cilium.yaml) · [server3](../iac/clusters/server3/helm-values/cilium.yaml) | [values.yaml](https://github.com/cilium/cilium/blob/main/install/kubernetes/cilium/values.yaml) |
| [Gateway API](https://gateway-api.sigs.k8s.io/) | Standard Kubernetes ingress/routing CRDs; installed before Cilium | all | Terraform `platform` | — | — | — |
| [Longhorn](https://longhorn.io/) | Distributed block storage | all | Terraform `platform` | [longhorn](https://artifacthub.io/packages/helm/longhorn/longhorn) | [shared](../iac/clusters/helm-values/longhorn.yaml) · [server1](../iac/clusters/server1/helm-values/longhorn.yaml) · [server2](../iac/clusters/server2/helm-values/longhorn.yaml) · [server3](../iac/clusters/server3/helm-values/longhorn.yaml) | [values.yaml](https://github.com/longhorn/longhorn/blob/master/chart/values.yaml) |
| [OpenBao](https://openbao.org/) | Secrets management; central backend for all clusters | server3 | Terraform `vault` | [openbao](https://artifacthub.io/packages/helm/openbao/openbao) | [server3](../iac/clusters/server3/helm-values/openbao.yaml) | [values.yaml](https://github.com/openbao/openbao-helm/blob/main/charts/openbao/values.yaml) |
| [ArgoCD](https://argoproj.github.io/cd/) | GitOps CD; manages workloads on all three clusters | server3 | Terraform `apps` | [argo-cd](https://artifacthub.io/packages/helm/argo/argo-cd) | [server3](../gitops/helm-values/server3/argocd.yaml) | [values.yaml](https://github.com/argoproj/argo-helm/blob/main/charts/argo-cd/values.yaml) |
| [External Secrets Operator](https://external-secrets.io/) | Sync secrets from OpenBao; ClusterSecretStore per cluster | server3 | ArgoCD | [external-secrets](https://artifacthub.io/packages/helm/external-secrets-operator/external-secrets) | [shared](../gitops/helm-values/external-secrets.yaml) · [server3](../gitops/helm-values/server3/external-secrets.yaml) | [values.yaml](https://github.com/external-secrets/external-secrets/blob/main/deploy/charts/external-secrets/values.yaml) |
| [Traefik](https://traefik.io/) | Ingress / Gateway API proxy; hostNetwork bare-metal LB | server3 | ArgoCD | [traefik](https://artifacthub.io/packages/helm/traefik/traefik) | [shared](../gitops/helm-values/traefik.yaml) · [server3](../gitops/helm-values/server3/traefik.yaml) | [values.yaml](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml) |
| [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/) | Automatic DNS via UniFi webhook; sources: gateway-httproute, traefik-proxy, crd | server3 | ArgoCD | [external-dns](https://artifacthub.io/packages/helm/external-dns/external-dns) | [shared](../gitops/helm-values/external-dns.yaml) · [server3](../gitops/helm-values/server3/external-dns.yaml) | [values.yaml](https://github.com/kubernetes-sigs/external-dns/blob/master/charts/external-dns/values.yaml) |
| [Headlamp](https://headlamp.dev/) | Kubernetes web UI | server3 | ArgoCD | [headlamp](https://artifacthub.io/packages/helm/headlamp/headlamp) | [shared](../gitops/helm-values/headlamp.yaml) · [server3](../gitops/helm-values/server3/headlamp.yaml) | [values.yaml](https://github.com/kubernetes-sigs/headlamp/blob/main/charts/headlamp/values.yaml) |
| [Hubble UI](https://docs.cilium.io/en/stable/observability/hubble/) | Cilium network observability UI | server3 | ArgoCD | — | — | — |
| [Longhorn UI](https://longhorn.io/) | Distributed storage dashboard | server3 | ArgoCD | — | — | — |
| [MinIO](https://min.io/) | S3 storage for Terraform state and Longhorn backups | server3 | ArgoCD | — | — | — |

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
│  5. ArgoCD GitOps        → RootInfra (ESO + ClusterSecretStore)         │
│     [manual: kubectl apply RootGateway → Traefik + ExternalDNS]         │
│     [manual: kubectl apply server3/RootDashboards → OpenBaoRoute]          │
│     [manual: kubectl apply RootDashboards → Headlamp + Hubble + Longhorn] │
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
