# IaC Guide

Terraform manages three stages for the **server3** cluster and two stages for **server1** and **server2**.
Shared logic lives in `iac/modules/`; cluster-specific values are inlined in `iac/clusters/<cluster>/<stage>/main.tf`.

## Prerequisites

```bash
brew install terraform
brew install kubectl
brew install siderolabs/tap/talosctl
brew install argoproj/tap/argocd
brew install openbao        # bao CLI — for OpenBao (server3 secrets backend)
brew install helm
```

## Directory structure

```
iac/
  modules/
    bootstrap/          Talos machine secrets, config generation, cluster bootstrap, kubeconfig write
      patches/
        cilium.yaml     Universal: disable Flannel + kube-proxy (required for Cilium)
        scheduling.yaml Universal: allow scheduling on control-plane (single-node clusters)
    platform/           Gateway API CRDs, Cilium, Longhorn
    apps/               ArgoCD namespace + secret + Helm install + self-management Application
  clusters/
    server1/            bootstrap/ platform/ helm-values/
    server2/            bootstrap/ platform/ helm-values/
    server3/            bootstrap/ platform/ vault/ apps/ helm-values/
gitops/
  helm-values/
    external-dns.yaml        shared: Unifi webhook, sources (gateway-httproute, traefik-proxy, crd)
    external-secrets.yaml    shared: installCRDs: true
    headlamp.yaml            shared: httpRoute + clusterRoleBinding
    traefik.yaml             shared: hostNetwork, Gateway API, bare-metal service
    server3/
      argocd.yaml            ArgoCD Helm overrides
      external-dns.yaml      domainFilters, txtOwnerId
      headlamp.yaml          hostname: headlamp.server3.home
      traefik.yaml           dashboard, externalIPs, statusAddress.ip
  argocd-manifests/
    ArgoCD.yaml              ArgoCD self-management
    RootInfra.yaml           App-of-Apps → apps/infra/
    RootGateway.yaml         App-of-Apps → apps/gateway/
    RootDashboards.yaml       App-of-Apps → apps/dashboards/
    apps/
      infra/    ESO (AppSet, list generator)
      gateway/  Traefik (AppSet), ExternalDNS (AppSet)
      ui/       Headlamp (AppSet), Hubble (AppSet), Longhorn (AppSet)
    server3/
      RootDashboards.yaml    App-of-Apps → server3/apps/dashboards/ (server3-only singletons)
      apps/
        ui/   OpenBao.yaml    App: vault.server3.home HTTPRoute
  k8s-manifests/
    server3/
      cilium/              HTTPRoute: hubble.server3.home → hubble-dashboard:80
      external-dns/        ExternalSecret (unifi-credentials), DNSEndpoint (server3.home)
      external-secrets/    ClusterSecretStore → local OpenBao
      longhorn/            HTTPRoute: longhorn.server3.home → longhorn-frontend:80
      openbao/             HTTPRoute: vault.server3.home → openbao:8200
```

Each `iac/clusters/<name>/<stage>/main.tf` contains:
- `terraform {}` block with required providers + S3 backend config (commented until MinIO is live)
- Provider configuration blocks
- A single `module {}` call with cluster-specific values inline

## Bootstrap sequence

### Server3 cluster (ArgoCD is installed here)

```bash
# 1. Talos cluster + kubeconfig/talosconfig
cd iac/clusters/server3/bootstrap && terraform init && terraform apply -auto-approve

# 1.a Cilium device (update cilium helm values)
talosctl get links -n 192.168.1.20X

# 1.b Disks (update disks in terraform values)
talosctl get disks -n 192.168.1.20X

# 2. Gateway API CRDs + Cilium + Longhorn
cd iac/clusters/server3/platform && terraform init && terraform apply -auto-approve

# 3. OpenBao
cd iac/clusters/server3/vault && terraform init && terraform apply -auto-approve

# 3.a Init (run once — save the unseal keys and root token somewhere safe)
kubectl exec -n openbao openbao-0 -- bao operator init

# 3.b Unseal (repeat with 3 different unseal keys from the init output)
kubectl exec -n openbao openbao-0 -- bao operator unseal <unseal-key-1>
kubectl exec -n openbao openbao-0 -- bao operator unseal <unseal-key-2>
kubectl exec -n openbao openbao-0 -- bao operator unseal <unseal-key-3>

# 3.c Login and configure KV engine (port-forward required for local bao CLI)
kubectl port-forward -n openbao svc/openbao 8200:8200
export BAO_ADDR=http://127.0.0.1:8200
bao login <root-token>
bao secrets enable -path=secret kv-v2

# 3.d Configure Kubernetes auth (required by ESO ClusterSecretStore)
#     Continue in the same port-forward session — bao login already persisted the token.
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

# Policy: read-only access to all KV v2 secrets
bao policy write read-secrets - <<'EOF'
path "secret/data/*" { capabilities = ["read"] }
EOF

# Role: bind the ESO ServiceAccount to the policy
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=read-secrets \
  ttl=24h

# 4. ArgoCD install
# Prerequisites: OpenBao port-forward must be running and vault credentials exported.
kubectl port-forward -n openbao svc/openbao 8200:8200
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(cat ~/.vault-token)   # set after: bao login <root-token>
cd iac/clusters/server3/apps && terraform init && terraform apply -auto-approve

# 5. Apply ArgoCD self-management + infra stage
kubectl apply -f gitops/argocd-manifests/ArgoCD.yaml
kubectl apply -f gitops/argocd-manifests/RootInfra.yaml
# Wait for ESO + ClusterSecretStore to become ready before continuing:
kubectl wait --for=condition=Ready clusterSecretStore/openbao -n external-secrets --timeout=120s

# 5.a Seed secrets in OpenBao before applying the gateway stage.
#     The ExternalDNS ExternalSecret will pull these on its first sync.
#     OpenBao is not yet exposed via Traefik at this point — use port-forward.
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
bao login                                                            # enter root token
bao kv put secret/server3/external-dns api-key=<unifi-api-key>
# Verify: bao kv get secret/server3/external-dns

# 6. Apply gateway stage
kubectl apply -f gitops/argocd-manifests/RootGateway.yaml
# ArgoCD auto-syncs Traefik + ExternalDNS from that point on.

# 6.a Apply server3-specific singleton Applications
#     Discovered by server3/RootDashboards — applied once, ArgoCD self-heals from then on.
kubectl apply -f gitops/argocd-manifests/server3/RootDashboards.yaml
# OpenBao is now accessible at vault.server3.home via Traefik.

# 7. Apply UI stage (Headlamp, Hubble, Longhorn UI)
kubectl apply -f gitops/argocd-manifests/RootDashboards.yaml
# ArgoCD auto-syncs UI apps from that point on.
```

### Server1 / Server2 cluster (managed by server3 ArgoCD)

```bash
# 1. Talos cluster + kubeconfig/talosconfig
cd iac/clusters/<cluster>/bootstrap && terraform init && terraform apply -auto-approve

# 1.a Cilium device (update cilium helm values)
talosctl get links -n 192.168.1.20X

# 1.b Disks (update disks in terraform values)
talosctl get disks -n 192.168.1.20X

# 2. Gateway API CRDs + Cilium + Longhorn
cd iac/clusters/<cluster>/platform && terraform init && terraform apply -auto-approve

# 3. Register the cluster in server3 ArgoCD
export KUBECONFIG=iac/clusters/<cluster>/credentials/kubeconfig
argocd cluster add <context-name> --name <cluster>
argocd cluster list   # note the SERVER URL; check destination.server in leaf Applications

# 4. Store the cluster's ExternalDNS Unifi API key in OpenBao:
bao kv put secret/<cluster>/external-dns api-key=<unifi-api-key>

# 5. Add this cluster to each ApplicationSet's list generator.
#    In each file under gitops/argocd-manifests/apps/infra/,
#    apps/gateway/, and apps/dashboards/, add under spec.generators[0].list.elements:
#      - cluster: <cluster>
#        clusterServer: <server-url>  # from: argocd cluster list
#    Commit and push — server3 ArgoCD auto-generates all Applications for this cluster.
```

## Module variable reference

### modules/bootstrap

| Variable | Type | Description |
|----------|------|-------------|
| `cluster_name` | string | Talos/Kubernetes cluster name |
| `controlplane_ips` | list(string) | Control-plane node IPs |
| `worker_ips` | list(string) | Worker node IPs (empty = single-node) |
| `cluster_vip` | string | Virtual IP for HA clusters (optional) |
| `talos_version` | string | Talos Linux version (e.g. `v1.12.6`) |
| `kubernetes_version` | string | Kubernetes version (e.g. `1.35.2`) |
| `talos_schematic_id` | string | Image Factory schematic ID — controls system extensions |
| `install_disk_selector` | map(string) | Talos `diskSelector` for OS disk (e.g. `{ wwid = "..." }`) |
| `longhorn_disks` | map(string) | Per-node dedicated Longhorn disk paths (optional) |
| `credentials_dir` | string | Where to write kubeconfig + talosconfig (pass `"${path.root}/../credentials"`) |

Outputs: `kubeconfig_path`, `talosconfig_path`, `cluster_endpoint`, `controlplane_nodes`, `worker_nodes`

### modules/platform

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `kubeconfig_path` | string | — | Absolute path to kubeconfig |
| `cilium_version` | string | — | Cilium chart version |
| `longhorn_version` | string | — | Longhorn chart version |
| `gateway_api_version` | string | — | Gateway API CRD tag (without `v`) |
| `cilium_values` | string | — | Cilium Helm values content (`file(...)`) |
| `longhorn_values` | string | `""` | Longhorn Helm values content (`file(...)`) |
| `enable_longhorn` | bool | `true` | Set false if using another CSI driver |

Outputs: `cilium_version`, `longhorn_version`

### modules/vault

| Variable | Type | Description |
|----------|------|-------------|
| `kubeconfig_path` | string | Absolute path to kubeconfig |
| `openbao_version` | string | OpenBao Helm chart version |
| `openbao_values` | string | OpenBao Helm values content (`file(...)`) |

Outputs: `openbao_version`

### modules/apps

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `kubeconfig_path` | string | — | Absolute path to kubeconfig |
| `argocd_chart_version` | string | — | argo-cd chart version |
| `argocd_values` | string | — | ArgoCD Helm values content (`file(...)`) |
| `argocd_vault_secret_path` | string | `"argocd"` | OpenBao KV v2 path (mount `secret`) holding `adminPasswordHash`. Use cluster-scoped paths, e.g. `server3/argocd` |
| `argocd_self_manage_yaml` | string | `""` | ArgoCD.yaml manifest content; empty = skip |

Outputs: none

## ArgoCD admin credential in OpenBao

The ArgoCD admin password is stored as a pre-computed bcrypt hash in OpenBao. This avoids
plaintext in Terraform state and prevents re-hashing (new salt) on every `terraform apply`.

```bash
# 1. Generate bcrypt hash of your chosen password (htpasswd ships with macOS)
htpasswd -bnBC 10 "" YOUR_PASSWORD | tr -d ':\n'

# 2. Store in OpenBao (port-forward must be running)
export BAO_ADDR=http://127.0.0.1:8200
bao kv put secret/server3/argocd adminPasswordHash='$2a$10$...'
```

Note: bcrypt is an ArgoCD requirement — `argocd-secret` must contain a bcrypt hash.
All other app secrets in OpenBao are stored as plaintext.

## Helm values for Terraform-managed components

Cilium and Longhorn values are cluster-specific and only used by Terraform — they live inside the cluster directory:
- `iac/clusters/<cluster>/helm-values/cilium.yaml`
- `iac/clusters/<cluster>/helm-values/longhorn.yaml`

ArgoCD values live in `gitops/helm-values/server3/` (server3 only):
- `gitops/helm-values/server3/argocd.yaml`

Terraform reads the ArgoCD values during initial bootstrap via a relative `file()` path. After bootstrap, ArgoCD manages its own upgrade from the same file via its self-management Application.

## Upgrading a Terraform-managed component

1. Update the version variable in `iac/clusters/<cluster>/<stage>/main.tf`
2. Review the diff between old and new upstream `values.yaml` against the local override file
3. Apply: `cd iac/clusters/<cluster>/<stage> && terraform apply -auto-approve`

When upgrading across all clusters, update each cluster's `main.tf` separately.

## Adding a new cluster

1. Copy `iac/clusters/server2/` as a template (bootstrap + platform only — no apps stage)
2. Update `cluster_name`, `controlplane_ips`, `install_disk_selector`, `talos_schematic_id`
3. Update `devices:` in `helm-values/cilium.yaml` to the correct network interface
4. Bootstrap: run `terraform apply -auto-approve` for bootstrap and platform stages
5. Register the cluster kubeconfig in server3 ArgoCD (`argocd cluster add`)
6. Apply the cluster's Application manifests from `gitops/`

## State backend migration to MinIO

MinIO runs on the server3 cluster, deployed by ArgoCD. The server3 cluster's own Terraform state starts
as local files and is migrated after MinIO is live.

### Server3 cluster migration (one-time, after MinIO is running)

```bash
# 1. Uncomment the backend "s3" {} block in each server3 stage main.tf
# 2. For each stage:
cd iac/clusters/server3/bootstrap
terraform init -migrate-state
# Accept the confirmation prompt — state is copied to MinIO

cd iac/clusters/server3/platform
terraform init -migrate-state

cd iac/clusters/server3/vault
terraform init -migrate-state

cd iac/clusters/server3/apps
terraform init -migrate-state
```

### New clusters (server1, future)

Uncomment the `backend "s3" {}` block before the first `terraform init`. No migration needed.

### S3 backend values to fill in

```hcl
backend "s3" {
  bucket                      = "terraform-state"
  key                         = "clusters/<cluster>/<stage>/terraform.tfstate"
  endpoint                    = "https://minio.server3.home"          # update to your MinIO URL
  region                      = "us-east-1"                        # MinIO ignores this
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  force_path_style            = true
}
```

Credentials are read from `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` environment variables or `~/.aws/credentials`.

## Talos schematic IDs

Each cluster may have a different schematic (different hardware extensions). Generate at https://factory.talos.dev.

Current base extensions (required for Longhorn iSCSI + disk utilities):
- `siderolabs/iscsi-tools`
- `siderolabs/util-linux-tools`

## Destroying the cluster

> ⚠️ Reset the node **before** destroying Terraform state — you need credentials to reach it.

```bash
# 1. Destroy apps and platform Helm releases
cd iac/clusters/<cluster>/apps     && terraform destroy -auto-approve
cd iac/clusters/<cluster>/platform && terraform destroy -auto-approve

# 2. Reset Talos while bootstrap credentials are still valid.
#    Wipes only STATE (config) + EPHEMERAL (k8s data). The Talos OS remains on
#    the NVMe (A/B partitions untouched) — node reboots into maintenance mode,
#    no USB/ISO needed.
export TALOSCONFIG=$(pwd)/credentials/talosconfig
talosctl reset \
  --system-labels-to-wipe STATE \
  --system-labels-to-wipe EPHEMERAL \
  --graceful=false \
  --reboot

# 3. Destroy bootstrap state (removes local credentials/ files too)
cd iac/clusters/<cluster>/bootstrap && terraform destroy -auto-approve
```