# Grafana InfluxDB2 Datasource on server3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an InfluxDB2 datasource to the Grafana instance on server3 so dashboards on server3 can query data from InfluxDB2 running on server2.

**Context:**
- InfluxDB2 runs on server2 in namespace `iot`, exposed externally at `http://influx.server2.home` via HTTPRoute.
- Grafana runs on server3 in namespace `monitoring`. It auto-discovers datasources from ConfigMaps labelled `grafana_datasource: "1"` in all namespaces (sidecar config in `gitops/helm-values/grafana.yaml`).
- Existing server3 datasource ConfigMaps: prometheus, loki, tempo — all at `gitops/k8s-manifests/server3/grafana/`.
- server3 and server2 are separate clusters — no `svc.cluster.local` path; must use the external HTTPRoute hostname.
- A read-only InfluxDB2 token scoped to the `loxone` and `loxone-downsample` buckets needs to be provisioned, stored in OpenBao, and synced to server3 via ESO.

**Architecture:** PostSync Job on server2 provisions a read-only InfluxDB2 token → writes to OpenBao `secret/server3/influxdb2-grafana`. ExternalSecret on server3 syncs it into namespace `monitoring`. ConfigMap on server3 declares the Grafana datasource pointing at `http://influx.server2.home`.

---

## Steps

### 1. Provision a read-only InfluxDB2 token for Grafana

- [ ] Create `gitops/k8s-manifests/server2/influxdb2/provisioner-grafana-datasource.yaml`:

```yaml
---
# InfluxDB2 PostSync provisioner: Grafana read token — create-only (idempotent)
# Runs on every ArgoCD sync. On first deploy:
#   1. Creates a read-only token scoped to loxone + loxone-downsample buckets
#   2. Writes the token to OpenBao: secret/server3/influxdb2-grafana
# On subsequent syncs: token already exists → skip (no-op).
# Consumed by: ExternalSecret influxdb2-grafana in monitoring namespace on server3
apiVersion: batch/v1
kind: Job
metadata:
  name: influxdb2-provision-grafana-datasource
  namespace: iot
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      restartPolicy: OnFailure
      automountServiceAccountToken: false
      containers:
        - name: provisioner
          image: alpine:3.20
          env:
            - name: INFLUX_TOKEN
              valueFrom:
                secretKeyRef:
                  name: influxdb2
                  key: admin-token
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: openbao-provision-token
                  key: token
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              apk add --no-cache curl jq > /dev/null

              INFLUX_HOST="http://influxdb2.iot.svc.cluster.local"
              ORG="homelab"
              TOKEN_DESC="grafana-read"
              BAO_HOST="http://vault.server3.home"

              # Idempotency: skip if token already exists
              EXISTING_ID=$(curl -sf \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                "${INFLUX_HOST}/api/v2/authorizations?org=${ORG}" \
                | jq -r --arg desc "${TOKEN_DESC}" \
                  '.authorizations[] | select(.description==$desc) | .id' | head -1)

              if [ -n "${EXISTING_ID}" ]; then
                echo "Token '${TOKEN_DESC}' already exists (${EXISTING_ID}). Skipping."
                exit 0
              fi

              # Get org ID
              ORG_ID=$(curl -sf \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                "${INFLUX_HOST}/api/v2/orgs?org=${ORG}" | jq -r '.orgs[0].id')

              # Get bucket IDs for loxone and loxone-downsample
              LOXONE_BUCKET_ID=$(curl -sf \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                "${INFLUX_HOST}/api/v2/buckets?org=${ORG}&name=loxone" \
                | jq -r '.buckets[0].id // empty')

              DOWNSAMPLE_BUCKET_ID=$(curl -sf \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                "${INFLUX_HOST}/api/v2/buckets?org=${ORG}&name=loxone-downsample" \
                | jq -r '.buckets[0].id // empty')

              # Build permissions array — only include buckets that exist
              PERMISSIONS="[]"
              if [ -n "${LOXONE_BUCKET_ID}" ]; then
                PERMISSIONS=$(echo "${PERMISSIONS}" | jq \
                  --arg org "${ORG_ID}" --arg id "${LOXONE_BUCKET_ID}" \
                  '. + [{"action":"read","resource":{"type":"buckets","id":$id,"orgID":$org}}]')
              fi
              if [ -n "${DOWNSAMPLE_BUCKET_ID}" ]; then
                PERMISSIONS=$(echo "${PERMISSIONS}" | jq \
                  --arg org "${ORG_ID}" --arg id "${DOWNSAMPLE_BUCKET_ID}" \
                  '. + [{"action":"read","resource":{"type":"buckets","id":$id,"orgID":$org}}]')
              fi

              # Create read-only token
              NEW_TOKEN=$(curl -sf -X POST \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                -H "Content-Type: application/json" \
                "${INFLUX_HOST}/api/v2/authorizations" \
                -d "{\"description\":\"${TOKEN_DESC}\",\"orgID\":\"${ORG_ID}\",\"permissions\":${PERMISSIONS}}" \
                | jq -r '.token')

              # Write token to OpenBao (server3 path — accessible to server3 ESO)
              curl -sf -X POST \
                -H "X-Vault-Token: ${BAO_TOKEN}" \
                -H "Content-Type: application/json" \
                "${BAO_HOST}/v1/secret/data/server3/influxdb2-grafana" \
                -d "{\"data\": {\"token\": \"${NEW_TOKEN}\"}}"

              echo "Token '${TOKEN_DESC}' created and written to OpenBao."
```

**Note:** Requires both `loxone` and `loxone-downsample` buckets to already exist. Deploy after `2026-04-24-influxdb2-loxone-downsampling` plan is executed, or make bucket creation a prerequisite in this job too.

### 2. Seed OpenBao path documentation

- [ ] Add to `docs/secrets.md` under the server3 iot/influxdb2 section:
```
secret/server3/influxdb2-grafana   token   Read-only Grafana datasource token (provisioned by PostSync Job)
```

### 3. Create ExternalSecret on server3

- [ ] Create `gitops/k8s-manifests/server3/grafana/ExternalSecret.influxdb2.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: influxdb2-grafana
  namespace: monitoring
  annotations:
    argocd.argoproj.io/sync-wave: "-50"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: influxdb2-grafana
  data:
    - secretKey: token
      remoteRef:
        key: server3/influxdb2-grafana
        property: token
```

### 4. Create Grafana datasource ConfigMap on server3

- [ ] Create `gitops/k8s-manifests/server3/grafana/ConfigMap.grafana.datasource.influxdb2.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-influxdb2
  namespace: monitoring
  labels:
    grafana_datasource: "1"
  annotations:
    argocd.argoproj.io/sync-wave: "-50"
data:
  datasource-influxdb2.yaml: |-
    apiVersion: 1
    datasources:
      - name: InfluxDB2
        type: influxdb
        uid: influxdb2
        access: proxy
        url: http://influx.server2.home
        editable: false
        jsonData:
          version: Flux
          organization: homelab
          defaultBucket: loxone
          tlsSkipVerify: true
        secureJsonData:
          token: $__file{/etc/secrets/influxdb2-grafana/token}
```

**Note on secret injection:** Grafana's sidecar datasource provisioning supports `$__file{...}` for reading secrets from mounted files. Need to also mount the secret as a volume in Grafana. See step 5.

### 5. Mount the ExternalSecret in Grafana

- [ ] Add to `gitops/helm-values/server3/grafana.yaml`:

```yaml
extraSecretMounts:
  - name: influxdb2-grafana
    secretName: influxdb2-grafana
    defaultMode: 0440
    mountPath: /etc/secrets/influxdb2-grafana
    readOnly: true
```

Alternatively, use `$__env{INFLUXDB2_TOKEN}` with `envFromSecret` — but file mount is preferred to avoid token appearing in `kubectl describe pod` env output.

### 6. Verify

- [ ] Force-sync the InfluxDB2 ArgoCD Application on server2. Confirm `influxdb2-provision-grafana-datasource` Job succeeds.
- [ ] Check OpenBao: `bao kv get secret/server3/influxdb2-grafana` — token field present.
- [ ] Force-sync the Grafana ArgoCD Application on server3. Confirm ExternalSecret `influxdb2-grafana` is `Ready`.
- [ ] Open `http://grafana.server3.home` → Configuration → Data Sources. Confirm `InfluxDB2` datasource appears.
- [ ] Click "Save & Test" — expect "datasource is working. X buckets found."

---

## Notes

- `tlsSkipVerify: true` — InfluxDB2 is served over plain HTTP at `influx.server2.home`, so TLS skip is irrelevant here but harmless. Remove if HTTPS is added later.
- The Grafana datasource uses Flux query language (`version: Flux`). InfluxQL mode would require a different config (`version: InfluxQL`, `database: loxone`, no `organization` field).
- Token is scoped read-only to `loxone` and `loxone-downsample` buckets only. If additional buckets need querying from server3 Grafana, re-provision the token with expanded permissions (delete old token from InfluxDB2 and the OpenBao key, then re-sync to trigger provisioner).
