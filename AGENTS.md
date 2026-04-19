# Agent Guidelines — homelab

Kubernetes homelab: three Talos Linux clusters managed with Terraform (IaC) and ArgoCD (GitOps).
See [README.md](README.md) for cluster overview. See [docs/architecture.md](docs/architecture.md) for decisions and roadmap.

## Repository layout

```
iac/
  modules/
    bootstrap/    Talos cluster provisioning (reusable module)
    platform/     Cilium, Longhorn, Gateway API CRDs (reusable module)
    vault/      OpenBao (server3 only)
    apps/         ArgoCD install + self-management bootstrap (reusable module, server3 only)
  clusters/
    server1/      bootstrap/ platform/ helm-values/
    server2/      bootstrap/ platform/ helm-values/
    server3/      bootstrap/ platform/ vault/ apps/ helm-values/
gitops/
  helm-values/
    external-dns.yaml       shared: Unifi webhook provider, sources (gateway-httproute, traefik-proxy, crd), policy
    external-secrets.yaml   shared: installCRDs: true
    headlamp.yaml           shared: httpRoute + clusterRoleBinding
    traefik.yaml            shared: hostNetwork, Gateway API provider, listeners, bare-metal service
    server1/      cluster overrides (empty until server1 is onboarded)
    server3/
      argocd.yaml           ArgoCD helm overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides (currently empty)
      headlamp.yaml         hostname: headlamp.server3.home
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip
  argocd-manifests/
    ArgoCD.yaml             ArgoCD self-management (cluster-agnostic)
    server3/
      RootInfra.yaml        App-of-Apps → server3/apps/infra/
      RootGateway.yaml      App-of-Apps → server3/apps/gateway/
      RootUI.yaml           App-of-Apps → server3/apps/ui/
      apps/
        infra/    ESO.yaml, OpenBaoRoute.yaml
        gateway/  Traefik.yaml, ExternalDNS.yaml
        ui/       Headlamp.yaml, Hubble.yaml, LonghornUI.yaml
  k8s-manifests/
    server3/
      cilium/              HTTPRoute: hubble.server3.home → hubble-ui:80
      external-dns/        ExternalSecret (unifi-credentials), DNSEndpoint (server3.home A record)
      external-secrets/    ClusterSecretStore → local OpenBao
      longhorn/            HTTPRoute: longhorn.server3.home → longhorn-frontend:80
      openbao/             HTTPRoute: vault.server3.home → openbao:8200
  shared/
    helm-charts/  Custom Helm charts used across clusters
docs/             Architecture decisions, IaC guide, secrets guide
```

## Module + cluster instance pattern

Modules in `iac/modules/` contain reusable Terraform logic.  
Cluster instances in `iac/clusters/<name>/` call the modules with cluster-specific values.  
Never put provider configurations inside modules — only in cluster instances.

When changing a module, validate all cluster instances that call it:
```bash
cd iac/clusters/<name>/<stage> && terraform validate
```

## Two installation paths

### 1. Terraform-managed (bootstrap / platform / vault / apps)

| Component | Version location |
|-----------|-----------------|
| Talos Linux | `iac/clusters/<cluster>/bootstrap/main.tf` — `talos_version` |
| Kubernetes | `iac/clusters/<cluster>/bootstrap/main.tf` — `kubernetes_version` |
| Cilium | `iac/clusters/<cluster>/platform/main.tf` — `cilium_version` |
| Longhorn | `iac/clusters/<cluster>/platform/main.tf` — `longhorn_version` |
| Gateway API CRDs | `iac/clusters/<cluster>/platform/main.tf` — `gateway_api_version` |
| ArgoCD | `iac/clusters/server3/apps/main.tf` — `argocd_chart_version` (server3 only) |
| OpenBao | `iac/clusters/server3/vault/main.tf` — `openbao_version` (server3 only) |

To apply a version change: `cd iac/clusters/<cluster>/<stage> && terraform apply -auto-approve`

### 2. ArgoCD-managed (GitOps)

All other apps use the **app-of-apps** pattern with two stages per cluster:
- **infra** stage: ESO + supporting K8s resources (ClusterSecretStore, OpenBao HTTPRoute)
- **gateway** stage: Traefik + ExternalDNS + ExternalSecret for Unifi credentials

Root Application CRDs live in `gitops/argocd-manifests/<cluster>/` as `RootInfra.yaml` / `RootGateway.yaml` / `RootUI.yaml`.
They discover child Applications from `gitops/argocd-manifests/<cluster>/apps/<stage>/`.
`destination.server` in each leaf Application selects which cluster the workload deploys to.
Version is `targetRevision` in that file. ArgoCD auto-syncs on commit.

`ArgoCD.yaml` (self-management) lives at `gitops/argocd-manifests/ArgoCD.yaml` — not under any cluster subdirectory.

Helm values use a two-layer approach:
- **Shared base**: `gitops/helm-values/<name>.yaml` — common across all clusters
- **Cluster overrides**: `gitops/helm-values/<cluster>/<name>.yaml` — cluster-specific values (merged last, wins)

Both files are listed in `valueFiles` in the Application manifest. Only add a cluster-specific file when there are actual overrides.

Raw Kubernetes manifests live in `gitops/k8s-manifests/<cluster>/<app>/`.

## Version sync rules — MUST follow

When changing any component version:
1. Update the version in the relevant `iac/clusters/<cluster>/<stage>/main.tf` or Application CRD
2. Update the `Upstream values.yaml` link if the component has one in a README table

## Vault

OpenBao is deployed via `iac/clusters/server3/vault/` (Terraform-managed, server3 only).
App secrets are stored in OpenBao and synced to all clusters via External Secrets Operator.
After `terraform apply`, run the init ceremony manually (see `iac/clusters/server3/vault/main.tf` header).
See [docs/secrets.md](docs/secrets.md) once that file is created.

## Credentials

Written to `iac/clusters/<cluster>/credentials/` (gitignored) by the bootstrap stage.
Access using:
```bash
export KUBECONFIG=iac/clusters/<cluster>/credentials/kubeconfig
export TALOSCONFIG=iac/clusters/<cluster>/credentials/talosconfig
```

## Operational commands

### Run freely (read-only / safe)

```bash
# Terraform
terraform plan
terraform validate
terraform output

# Kubernetes
kubectl get <resource>
kubectl describe <resource>
kubectl logs <pod>

# Talos
talosctl health
talosctl logs <service>
talosctl get disks

# ArgoCD
kubectl get applications -n argocd
kubectl describe application <name> -n argocd

# Git (local only)
git status / git diff / git log
```

### Run freely (intended write operations)

```bash
terraform apply -auto-approve      # version bumps and config changes
sops --encrypt --in-place <file>   # encrypting new secrets

# ArgoCD — force refresh or kill stuck sync
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=normal
kubectl patch application <name> -n argocd --type merge -p '{"operation": null}'
```

### Ask before running (destructive / irreversible)

```bash
terraform destroy
talosctl upgrade
talosctl reset
talosctl wipe disk
kubectl delete <resource>
rm -rf / any deletion of credentials
```

## Adding a new cluster

1. Copy `iac/clusters/server2/` as the template (bootstrap + platform only — no apps stage)
2. Fill in cluster-specific values (IPs, disk selectors, schematic ID) in each `main.tf`
3. Update Cilium `devices: "TODO"` to the correct network interface
4. Bootstrap: run `terraform apply -auto-approve` for bootstrap and platform stages
5. Register the cluster in server3 ArgoCD: `argocd cluster add <context>`
6. Apply the cluster's Application manifests from `gitops/`

## Adding a new ArgoCD app

1. Create `gitops/argocd-manifests/server3/<Name>.yaml` — copy an existing Application as template, set `destination.server` for the target cluster
2. Add helm values at `gitops/helm-values/<cluster>/<name>.yaml`
3. Add raw manifests to `gitops/k8s-manifests/<cluster>/<name>/` if needed

## State backend migration (MinIO)

Once MinIO is running on the server3 cluster:
1. Uncomment the `backend "s3" {}` block in each `main.tf`
2. Run `terraform init -migrate-state` to move local state to MinIO
3. New clusters (server1) can use MinIO from the start — no migration needed
See [docs/iac.md](docs/iac.md) for the full migration sequence.
