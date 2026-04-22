# OTel Gateway Bearer Token Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Secure the OTel Gateway ingestion endpoints on server3 with bearer token authentication so only authorised cluster forwarders (server2, future server1) can push telemetry.

**Architecture:** A shared bearer token is stored in OpenBao (`secret/otel-gateway/auth-token`), synced to both server3 and server2 via ESO as a K8s Secret, and injected into the OTel collector pods as an env var. The server3 receiver validates the token via the `bearertokenauth` extension; server2 sends it as an `Authorization` header on the `otlp_grpc/server3` exporter.

**Tech Stack:** OpenBao KV v2, External Secrets Operator, `otel/opentelemetry-collector-contrib` (`bearertokenauth` extension), ArgoCD GitOps.

---

### Task 1: Store the token in OpenBao

**Files:**
- Modify: `docs/secrets.md` — add the new path to the quick-reference table

- [ ] **Step 1: Generate and store the token**

```bash
export BAO_ADDR=http://vault.server3.home
bao login <root-token>

bao kv put secret/otel-gateway/auth-token \
  token=$(openssl rand -base64 32 | tr -d '=+/')
```

- [ ] **Step 2: Verify**

```bash
bao kv get secret/otel-gateway/auth-token
# Expected: token = <32-char base64 string>
```

- [ ] **Step 3: Add to secrets.md quick-reference table**

In `docs/secrets.md`, insert a row into the quick reference table:

```markdown
| `secret/otel-gateway/auth-token` | `token` | observability stage | server3, server2 |
```

- [ ] **Step 4: Commit**

```bash
git add docs/secrets.md
git commit -m "docs: add otel-gateway auth token to secrets reference"
```

---

### Task 2: ExternalSecret on server3

**Files:**
- Create: `gitops/k8s-manifests/server3/otel-gateway/ExternalSecret.otel-auth-token.yaml`

- [ ] **Step 1: Create the ExternalSecret manifest**

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: otel-auth-token
  namespace: monitoring
  labels:
    app.kubernetes.io/name: otel-gateway
    app.kubernetes.io/component: observability
  annotations:
    argocd.argoproj.io/sync-wave: "-50"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: otel-auth-token
    creationPolicy: Owner
  data:
    - secretKey: OTEL_AUTH_TOKEN
      remoteRef:
        key: secret/otel-gateway/auth-token
        property: token
```

- [ ] **Step 2: Verify the ClusterSecretStore name**

```bash
kubectl get clustersecretstore --kubeconfig iac/clusters/server3/credentials/kubeconfig
# Expected: a store named "openbao" (or check gitops/k8s-manifests/server3/external-secrets/ClusterSecretStore.yaml)
```

If the store name differs, update `secretStoreRef.name` accordingly.

- [ ] **Step 3: Commit**

```bash
git add gitops/k8s-manifests/server3/otel-gateway/ExternalSecret.otel-auth-token.yaml
git commit -m "feat: add ExternalSecret for otel-gateway auth token on server3"
```

---

### Task 3: ExternalSecret on server2

**Files:**
- Create: `gitops/k8s-manifests/server2/otel-gateway/ExternalSecret.otel-auth-token.yaml`

- [ ] **Step 1: Create the ExternalSecret manifest**

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: otel-auth-token
  namespace: monitoring
  labels:
    app.kubernetes.io/name: otel-gateway
    app.kubernetes.io/component: observability
  annotations:
    argocd.argoproj.io/sync-wave: "-50"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: otel-auth-token
    creationPolicy: Owner
  data:
    - secretKey: OTEL_AUTH_TOKEN
      remoteRef:
        key: secret/otel-gateway/auth-token
        property: token
```

- [ ] **Step 2: Verify the ClusterSecretStore name on server2**

```bash
kubectl get clustersecretstore --kubeconfig iac/clusters/server2/credentials/kubeconfig
# Expected: the same ClusterSecretStore pointing back to server3 OpenBao
```

- [ ] **Step 3: Commit**

```bash
git add gitops/k8s-manifests/server2/otel-gateway/ExternalSecret.otel-auth-token.yaml
git commit -m "feat: add ExternalSecret for otel-gateway auth token on server2"
```

---

### Task 4: Wire the ExternalSecrets into the ArgoCD ApplicationSets

**Files:**
- Modify: `gitops/argocd-manifests/apps/observability/OTelGateway.yaml` — add the ExternalSecret manifest path to `sources` or confirm the manifest directory is already synced

- [ ] **Step 1: Check how k8s-manifests are referenced for otel-gateway**

```bash
cat gitops/argocd-manifests/apps/observability/OTelGateway.yaml
```

Look for how `gitops/k8s-manifests/server3/otel-gateway/` manifests (HTTPRoute, IngressRouteTCP) are currently deployed. If they are in a separate Application or a multi-source Application, the new ExternalSecret YAML will be picked up automatically since it lives in the same directory.

- [ ] **Step 2: Confirm no manifest directory change is needed**

If the ArgoCD Application already syncs the full `gitops/k8s-manifests/<cluster>/otel-gateway/` directory, no change is required — ArgoCD will pick up the new file on next sync.

If a specific file list is used, add the new file path.

- [ ] **Step 3: Commit if changes were needed**

```bash
git add gitops/argocd-manifests/apps/observability/OTelGateway.yaml
git commit -m "feat: include otel-auth-token ExternalSecret in OTelGateway Application"
```

---

### Task 5: Update server3 OTel Gateway helm values

**Files:**
- Modify: `gitops/helm-values/server3/otel-gateway.yaml`

- [ ] **Step 1: Add `extraEnvsFrom`, `bearertokenauth` extension, and receiver auth**

Append to `gitops/helm-values/server3/otel-gateway.yaml`:

```yaml
extraEnvsFrom:
  - secretRef:
      name: otel-auth-token

config:
  extensions:
    bearertokenauth:
      token: "${env:OTEL_AUTH_TOKEN}"

  receivers:
    otlp:
      protocols:
        grpc:
          auth:
            authenticator: bearertokenauth
        http:
          auth:
            authenticator: bearertokenauth

  service:
    extensions: [health_check, bearertokenauth]
    pipelines:
      logs:
        receivers: [otlp]
      traces:
        receivers: [otlp]
      metrics:
        receivers: [otlp]
```

> Note: The `service.pipelines` entries only need to be present if the merge strategy requires explicit overrides. Check whether the shared base values are deep-merged by ArgoCD / Helm — if receiver/processor/exporter lists are inherited, only the `extensions` and `receivers.otlp.protocols` blocks are needed.

- [ ] **Step 2: Commit**

```bash
git add gitops/helm-values/server3/otel-gateway.yaml
git commit -m "feat: enable bearertokenauth on server3 otel-gateway receivers"
```

---

### Task 6: Update server2 OTel Gateway helm values

**Files:**
- Modify: `gitops/helm-values/server2/otel-gateway.yaml`

- [ ] **Step 1: Add `extraEnvsFrom` and `Authorization` header to the exporter**

In `gitops/helm-values/server2/otel-gateway.yaml`, extend the `otlp_grpc/server3` exporter:

```yaml
extraEnvsFrom:
  - secretRef:
      name: otel-auth-token

config:
  exporters:
    otlp_grpc/server3:
      endpoint: "otel.server3.home:4317"
      tls:
        insecure: true
      headers:
        Authorization: "Bearer ${env:OTEL_AUTH_TOKEN}"
```

- [ ] **Step 2: Commit**

```bash
git add gitops/helm-values/server2/otel-gateway.yaml
git commit -m "feat: add bearer token header to server2 otel-gateway exporter"
```

---

### Task 7: Push and verify

- [ ] **Step 1: Push all commits**

```bash
git push
```

- [ ] **Step 2: Wait for ArgoCD to sync both clusters**

```bash
# server3
kubectl get application -n argocd --kubeconfig iac/clusters/server3/credentials/kubeconfig | grep otel

# server2
kubectl get application -n argocd --kubeconfig iac/clusters/server2/credentials/kubeconfig | grep otel
```

Expected: both Applications show `Synced` / `Healthy`.

- [ ] **Step 3: Verify ExternalSecret synced on server3**

```bash
kubectl get secret otel-auth-token -n monitoring --kubeconfig iac/clusters/server3/credentials/kubeconfig
# Expected: secret exists with key OTEL_AUTH_TOKEN
```

- [ ] **Step 4: Verify ExternalSecret synced on server2**

```bash
kubectl get secret otel-auth-token -n monitoring --kubeconfig iac/clusters/server2/credentials/kubeconfig
# Expected: secret exists with key OTEL_AUTH_TOKEN
```

- [ ] **Step 5: Check server2 OTel collector is forwarding without errors**

```bash
KUBECONFIG2=iac/clusters/server2/credentials/kubeconfig
POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=opentelemetry-collector -o name --kubeconfig $KUBECONFIG2 | head -1)
kubectl logs -n monitoring $POD --kubeconfig $KUBECONFIG2 --tail=50 | grep -iE "error|refused|unauthorized|auth"
# Expected: no auth errors
```

- [ ] **Step 6: Verify unauthenticated push is rejected on server3**

```bash
# Should get a 401 / permission denied
curl -v -X POST http://otel.server3.home/v1/traces \
  -H "Content-Type: application/json" \
  -d '{}' 2>&1 | grep -E "HTTP|< "
# Expected: 401 Unauthorized
```

- [ ] **Step 7: Verify authenticated push is accepted**

```bash
TOKEN=$(kubectl get secret otel-auth-token -n monitoring \
  --kubeconfig iac/clusters/server3/credentials/kubeconfig \
  -o jsonpath='{.data.OTEL_AUTH_TOKEN}' | base64 -d)

curl -v -X POST http://otel.server3.home/v1/traces \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}' 2>&1 | grep -E "HTTP|< "
# Expected: 200 OK (empty payload is accepted)
```

---

### Future: token rotation

Rotation is explicitly deferred. When addressed, options are:

1. **KV v2 + ESO refresh** — write a new version of `secret/otel-gateway/auth-token` in OpenBao; ESO picks it up within `refreshInterval` (1h). The OTel pod will need a rolling restart because `extraEnvsFrom` bakes env vars at pod start. To avoid downtime, switch to a volume-mounted file and use the `bearertokenauth.filename` config key instead of `token`.

2. **AppRole + `vaultauth` extension** — replace `bearertokenauth` with the OTel `vaultauth` authenticator. Short-lived tokens are fetched directly from OpenBao by the collector. No ESO required for the token itself.
