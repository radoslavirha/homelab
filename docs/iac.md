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
    vault/              OpenBao Helm install
    apps/               ArgoCD namespace + secret + Helm install + self-management Application
  clusters/
    helm-values/        Shared Cilium + Longhorn values (all clusters)
    server1/            bootstrap/ platform/ helm-values/
    server2/            bootstrap/ platform/ helm-values/
    server3/            bootstrap/ platform/ vault/ apps/ helm-values/
```

> ArgoCD manifests, Helm values, and raw K8s manifests live in `gitops/` — see [gitops/README.md](../gitops/README.md).

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
bao auth enable -path=kubernetes-server3 kubernetes
bao write auth/kubernetes-server3/config kubernetes_host="https://kubernetes.default.svc:443"

# Policy: read-only access to all KV v2 secrets
bao policy write read-secrets - <<'EOF'
path "secret/data/*" { capabilities = ["read"] }
EOF

# Role: bind the ESO ServiceAccount to the policy
bao write auth/kubernetes-server3/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=read-secrets \
  ttl=24h

# 4. ArgoCD install
# ⚠️  PREREQUISITES: the following secrets must exist in OpenBao before ArgoCD syncs:
#    - secret/server3/argocd → See docs/secrets.md → "server3/argocd" for the bcrypt hash command.
#    - secret/server3/grafana → Grafana admin credentials (observability stage).

# Seed Grafana admin credentials (observability stage):
bao kv put secret/server3/grafana \
  admin-user=admin \
  admin-password=<strong-password>

# Prerequisites: OpenBao port-forward must be running and vault credentials exported.
kubectl port-forward -n openbao svc/openbao 8200:8200
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(cat ~/.vault-token)   # set after: bao login <root-token>
cd iac/clusters/server3/apps && terraform init && terraform apply -auto-approve

# 5. Bootstrap GitOps stages (ArgoCD root Applications)
#    See gitops/README.md → "Bootstrap sequence".
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

# Switch kubectl context to the new cluster for all steps below:
kubectl config use-context <cluster>

# 3. Configure OpenBao — all vault work in a single session
#
#    OpenBao runs on server3 and is a REMOTE cluster from the perspective of the new cluster.
#    Perform ALL of the following sub-steps before moving to step 4, so that ESO, ExternalDNS,
#    and every datastore can pull their secrets on first sync without any follow-up vault sessions.
#
#    ── 3.a  Collect the token reviewer JWT from the NEW cluster ───────────────────────────────
#
#    ESO uses Kubernetes auth to log in to OpenBao. OpenBao needs a token reviewer JWT from the
#    new cluster's API server to validate those logins (TokenReview API). Without it, every ESO
#    login returns 403.

kubectl create serviceaccount openbao-token-reviewer -n kube-system
kubectl create clusterrolebinding openbao-token-reviewer \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kube-system:openbao-token-reviewer
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: openbao-token-reviewer
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: openbao-token-reviewer
type: kubernetes.io/service-account-token
EOF
REVIEWER_JWT=$(kubectl get secret openbao-token-reviewer -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d)
CLUSTER_CA=$(kubectl get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}')

#    ── 3.b  Open a single OpenBao session (server3 must be reachable) ────────────────────────
#
#    If vault.server3.home DNS is not yet resolving, use a port-forward instead:
#      kubectl port-forward -n openbao svc/openbao 8200:8200 --context server3 &
#      export BAO_ADDR=http://127.0.0.1:8200

export BAO_ADDR=http://vault.server3.home
bao login <root-token>

#    ── 3.c  Register Kubernetes auth mount for this cluster ───────────────────────────────────
#    One dedicated mount per cluster — never share mounts across clusters.

bao auth enable -path=kubernetes-<cluster> kubernetes
bao write auth/kubernetes-<cluster>/config \
  kubernetes_host="https://<controlplane-ip>:6443" \
  kubernetes_ca_cert="$CLUSTER_CA" \
  token_reviewer_jwt="$REVIEWER_JWT"

#    ── 3.d  ESO read-only policy + role ──────────────────────────────────────────────────────

bao policy write <cluster>-external-secrets - <<'EOF'
path "secret/data/<cluster>/*"     { capabilities = ["read"] }
path "secret/metadata/<cluster>/*" { capabilities = ["read", "list"] }
EOF

bao write auth/kubernetes-<cluster>/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=<cluster>-external-secrets \
  ttl=1h

#    ── 3.e  Provisioner write policy + long-lived token ──────────────────────────────────────
#    Provisioner Jobs (PostSync hooks) use this token to write scoped app credentials back to
#    OpenBao after calling each datastore's management API. See docs/provisioning.md for the
#    full PostSync Job pattern.

bao policy write <cluster>-provisioner - <<'EOF'
path "secret/data/<cluster>/*" { capabilities = ["create", "update"] }
EOF

PROVISIONER_TOKEN=$(bao token create \
  -policy=<cluster>-provisioner \
  -period=8760h \
  -display-name="<cluster>-provisioner" \
  -format=json | jq -r .auth.client_token)

# Store the provisioner token so provisioner Jobs can consume it via ESO:
bao kv put secret/<cluster>/provisioner-token token="$PROVISIONER_TOKEN"

#    ── 3.f  Seed initial KV secrets ──────────────────────────────────────────────────────────
#    ⚠️  PREREQUISITE: all secrets below MUST exist in OpenBao before any ArgoCD stage
#    is committed for this cluster. ESO syncs immediately on first Application sync —
#    missing paths cause ExternalSecrets to fail and pods to crashloop.
#    See docs/secrets.md for full details and verification commands.
#    These secrets must exist before ESO syncs for the first time (steps 5 onwards).
#    Add all secrets for every app you plan to deploy on this cluster.

#    ExternalDNS — UniFi API key (gateway stage):
bao kv put secret/<cluster>/external-dns api-key=<unifi-api-key>

#    InfluxDB2 admin credentials (iot stage; ESO syncs before pod starts):
#      admin-token: any 20+ char string — InfluxDB2 accepts arbitrary values.
#      Generate: openssl rand -base64 24 | tr -d '=+/'
#      See docs/provisioning.md for per-app token provisioning after first start.
bao kv put secret/<cluster>/influxdb2 \
  admin-password=<password> \
  admin-token=<token>

#    EMQX dashboard credentials (iot stage):
#      dashboard-username: admin username for EMQX dashboard (e.g. admin).
#      dashboard-password: strong password (20+ chars).
#      See docs/provisioning.md for per-app credential provisioning after first start.
bao kv put secret/<cluster>/emqx \
  dashboard-username=<username> \
  dashboard-password=<password>

#    MongoDB root password (databases stage; ESO syncs before pod starts):
#      root-password: strong password (20+ chars).
#      See docs/provisioning.md for per-app user provisioning after first start.
bao kv put secret/<cluster>/mongodb \
  root-password=<password>

#    Verify all secrets are present before continuing:
bao kv list secret/<cluster>

# 4. Register the cluster in server3 ArgoCD
#    Context must still be set to <cluster> (set above)
argocd cluster add <context-name> --name <cluster>
argocd cluster list   # note the SERVER URL; matches clusterServer in ApplicationSet elements

# 5. Bootstrap GitOps stages for this cluster
#    See gitops/README.md → "Bootstrap sequence".
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

Cilium and Longhorn values are two-layered and only used by Terraform:
- **Shared base**: `iac/clusters/helm-values/cilium.yaml` / `longhorn.yaml` — common values across all clusters
- **Cluster overrides**: `iac/clusters/<cluster>/helm-values/cilium.yaml` / `longhorn.yaml` — cluster-specific values (merged last, wins)

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
6. Bootstrap GitOps stages — see [gitops/README.md](../gitops/README.md) → "Bootstrap sequence"

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