# Quick Start

All commands to provision the homelab from zero. Fill in values marked `<like-this>`.

For the background, rationale, and troubleshooting see the [reference docs](#reference-docs) at the bottom.

---

## Server3

Server3 hosts OpenBao, ArgoCD, and the observability stack. Provision it first.

### Step 1 — Talos cluster

```bash
cd iac/clusters/server3/bootstrap && terraform init && terraform apply -auto-approve
```

Before the next step, update two config files:

```bash
# Find the network interface name (e.g. enp3s0):
talosctl get links -n <server3-ip>
# → update devices: in iac/clusters/server3/helm-values/cilium.yaml

# Find the Longhorn data disk (the non-OS disk):
talosctl get disks -n <server3-ip>
# → update longhorn_disks: in iac/clusters/server3/bootstrap/main.tf
```

### Step 2 — Platform (Cilium + Longhorn + Gateway API)

```bash
cd iac/clusters/server3/platform && terraform init && terraform apply -auto-approve
```

### Step 3 — OpenBao

```bash
cd iac/clusters/server3/vault && terraform init && terraform apply -auto-approve

# Init — save all 5 unseal keys and the root token somewhere safe (cannot be recovered):
kubectl exec -n openbao openbao-0 -- bao operator init

# Unseal (run 3 times with 3 different keys from the init output):
kubectl exec -n openbao openbao-0 -- bao operator unseal <key-1>
kubectl exec -n openbao openbao-0 -- bao operator unseal <key-2>
kubectl exec -n openbao openbao-0 -- bao operator unseal <key-3>

# Connect and configure:
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
bao login <root-token>

bao secrets enable -path=secret kv-v2

bao auth enable -path=kubernetes-server3 kubernetes
bao write auth/kubernetes-server3/config \
  kubernetes_host="https://kubernetes.default.svc:443"

bao policy write read-secrets - <<'EOF'
path "secret/data/*" { capabilities = ["read"] }
EOF

bao write auth/kubernetes-server3/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=read-secrets \
  ttl=24h
```

### Step 4 — Seed all server3 secrets (one session)

Do this in one block — all three paths must exist before ArgoCD syncs.

```bash
# ArgoCD admin password (bcrypt hash):
htpasswd -bnBC 10 "" <your-password> | tr -d ':\n'   # copy the output as HASH
bao kv put secret/server3/argocd adminPasswordHash='<bcrypt-hash>'

# Grafana admin:
bao kv put secret/server3/grafana \
  admin-user=admin \
  admin-password=<strong-password>

# ExternalDNS — UniFi API key:
bao kv put secret/server3/external-dns api-key=<unifi-api-key>

# Shared OTLP bearer token — used by every cluster's OTel Gateway.
# Lives at a non-cluster path; server2 ESO policy has an explicit read grant for it.
bao kv put secret/otel-gateway/auth-token token=$(openssl rand -base64 32 | tr -d '=+/')

# Verify:
bao kv list secret/server3
bao kv list secret/otel-gateway
```

### Step 5 — ArgoCD

```bash
# Port-forward from step 3 must still be running:
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(cat ~/.vault-token)

cd iac/clusters/server3/apps && terraform init && terraform apply -auto-approve
```

### Step 6 — GitOps stages

Two manual applies. `Bootstrap.yaml` is a meta App-of-Apps that discovers every Root App under `roots/` and orders deploys with sync waves (1 → 4). Each wave waits for the previous wave's Root Apps to reach Healthy before starting.

```bash
export KUBECONFIG=iac/clusters/server3/credentials/kubeconfig

# 1. ArgoCD self-management
kubectl apply -f gitops/argocd-manifests/ArgoCD.yaml

# 2. Bootstrap meta App-of-Apps
kubectl apply -f gitops/argocd-manifests/Bootstrap.yaml

# Watch progress:
kubectl get applications -n argocd -w
```

Wave layout:

|Wave|Root App(s)|Purpose|
|----|-----------|-------|
|1|`RootInfra`|ESO + CRDs|
|2|`RootGateway`, `server3/RootDashboards`|Traefik + ExternalDNS · OpenBao HTTPRoute|
|3|`RootObservability`, `server3/RootObservability`, `RootIoT`, `RootDatabases`, `RootDashboards`|OTel Gateway · LGTM · IoT · MongoDB · UI dashboards|
|4|`RootApps`|Custom apps (miot-bridge, interactive-map-feeder, apps-otel-collector)|

---

## Server2 / Server1

Run steps 1–6 for each cluster. Server3 must be fully operational first.

### Step 1 — Talos cluster

```bash
cd iac/clusters/<cluster>/bootstrap && terraform init && terraform apply -auto-approve

# Update config values before the next step:
talosctl get links -n <cluster-ip>
# → update devices: in iac/clusters/<cluster>/helm-values/cilium.yaml

talosctl get disks -n <cluster-ip>
# → update longhorn_disks: in iac/clusters/<cluster>/bootstrap/main.tf
```

### Step 2 — Platform

```bash
cd iac/clusters/<cluster>/platform && terraform init && terraform apply -auto-approve
kubectl config use-context <cluster>
```

### Step 3 — Configure OpenBao (single session — do not interrupt)

```bash
# Collect token reviewer JWT from the new cluster:
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
CLUSTER_CA=$(kubectl get configmap kube-root-ca.crt -n kube-system \
  -o jsonpath='{.data.ca\.crt}')

# Open an OpenBao session on server3:
# (if vault.server3.home DNS is not yet resolving, port-forward instead:
#  kubectl port-forward -n openbao svc/openbao 8200:8200 --context server3 &
#  export BAO_ADDR=http://127.0.0.1:8200)
export BAO_ADDR=http://vault.server3.home
bao login <root-token>

# Register auth mount for this cluster:
bao auth enable -path=kubernetes-<cluster> kubernetes
bao write auth/kubernetes-<cluster>/config \
  kubernetes_host="https://<controlplane-ip>:6443" \
  kubernetes_ca_cert="$CLUSTER_CA" \
  token_reviewer_jwt="$REVIEWER_JWT"

# ESO read-only policy + role:
bao policy write <cluster>-external-secrets - <<'EOF'
path "secret/data/<cluster>/*"     { capabilities = ["read"] }
path "secret/metadata/<cluster>/*" { capabilities = ["read", "list"] }
EOF
bao write auth/kubernetes-<cluster>/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=<cluster>-external-secrets \
  ttl=1h

# Provisioner write policy + long-lived token (for PostSync credential Jobs):
# `read` + `patch` + metadata `list` are needed so provisioner Jobs can check whether
# credentials already exist (idempotency) before deciding to create or rotate them.
bao policy write <cluster>-provisioner - <<'EOF'
path "secret/data/<cluster>/*"     { capabilities = ["create", "read", "update", "patch"] }
path "secret/metadata/<cluster>/*" { capabilities = ["read", "list"] }
EOF

PROVISIONER_TOKEN=$(bao token create \
  -policy=<cluster>-provisioner \
  -period=8760h \
  -display-name="<cluster>-provisioner" \
  -format=json | jq -r .auth.client_token)
bao kv put secret/<cluster>/provisioner-token token="$PROVISIONER_TOKEN"
```

### Step 4 — Seed all cluster secrets (one block)

```bash
# ExternalDNS — UniFi API key:
bao kv put secret/<cluster>/external-dns api-key=<unifi-api-key>

# InfluxDB2 admin credentials:
bao kv put secret/<cluster>/influxdb2 \
  admin-password=<password> \
  admin-token=$(openssl rand -base64 24 | tr -d '=+/')

# EMQX dashboard credentials:
bao kv put secret/<cluster>/emqx \
  dashboard-username=admin \
  dashboard-password=<password>

# MongoDB root password:
bao kv put secret/<cluster>/mongodb \
  root-password=<password>

# Verify:
bao kv list secret/<cluster>
```

### Step 5 — Register in ArgoCD

```bash
# Log in to server3 ArgoCD first (required by `argocd cluster add`).
# Admin password was seeded in OpenBao at secret/server3/argocd (bcrypt hash) during
# server3 step 4; use the plaintext value you hashed.
argocd login argocd.server3.home --username admin --password <plaintext-admin-password> --grpc-web --insecure --plaintext

argocd cluster add <context-name> --name <cluster>
argocd cluster list   # note the SERVER URL for step 6
```

### Step 6 — Activate GitOps

Add the new cluster to each ApplicationSet. Edit each file listed below and add one entry under `spec.generators[0].list.elements`:

```yaml
- cluster: <cluster>
  clusterServer: <server-url>   # from: argocd cluster list
```

Files to update:

```
gitops/argocd-manifests/apps/infra/ESO.yaml
gitops/argocd-manifests/apps/gateway/Traefik.yaml
gitops/argocd-manifests/apps/gateway/ExternalDNS.yaml
gitops/argocd-manifests/apps/observability/OTelGateway.yaml
gitops/argocd-manifests/apps/iot/InfluxDB2.yaml
gitops/argocd-manifests/apps/iot/EMQX.yaml
gitops/argocd-manifests/apps/databases/MongoDB.yaml
gitops/argocd-manifests/apps/dashboards/Headlamp.yaml
gitops/argocd-manifests/apps/dashboards/Hubble.yaml
gitops/argocd-manifests/apps/dashboards/Longhorn.yaml
```

Commit and push. Bootstrap on server3 already owns every Root App; adding the new cluster element triggers ArgoCD to generate one `Application` per stage for the new cluster. ApplicationSet sync is parallel across stages — ordering is enforced by resource-level sync waves inside each app (ExternalSecret retries, HTTPRoute `sync-wave: "100"`, Telegraf `sync-wave: "1"`, etc.), not by per-commit staging.

Monitor:

```bash
argocd app list | grep <cluster>
kubectl wait --for=condition=Ready clusterSecretStore/openbao \
  -n external-secrets --context <cluster> --timeout=120s
```

---

## Reference docs

| What | Where |
|------|-------|
| Full Terraform guide, module variables, destroying clusters | [docs/iac.md](iac.md) |
| Full secrets reference — what each path contains and why | [docs/secrets.md](secrets.md) |
| LGTM observability stack architecture | [docs/observability.md](observability.md) |
| Per-app credential provisioning (PostSync Jobs) | [docs/provisioning.md](provisioning.md) |
| ArgoCD app-of-apps structure, adding apps, adding clusters | [gitops/README.md](../gitops/README.md) |
