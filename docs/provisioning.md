# Dynamic Credential Provisioning

This document describes the strategy for provisioning application-level credentials (tokens, users, passwords) for datastores — without any Terraform stage or manual UI clicks.

## Problem

Datastores like InfluxDB2, EMQX, and MongoDB need per-app credentials scoped to a specific purpose (e.g., Telegraf gets a write-only token for the `loxone` bucket; Grafana gets a read-only token for all buckets). The root admin credential bootstraps the datastore, but connected apps should never use admin credentials.

Manual workflows — log in to UI, create token, copy to Vault, update consumer secret — break GitOps: credentials are not reproducible, rotation is painful, and adding a new app requires human intervention.

## Solution: ArgoCD PostSync Provisioner Job

Each datastore app has an optional companion **provisioner Job** per consumer that:

1. Reads the admin credential from the K8s Secret already synced by ESO
2. Calls the datastore's management API (idempotently — checks before creating)
3. Writes the resulting scoped credential to OpenBao via the `bao kv put` HTTP API
4. ESO's `ExternalSecret` in the consumer's namespace refreshes automatically on the next poll cycle

The Job uses `argocd.argoproj.io/hook: PostSync` and `argocd.argoproj.io/hook-delete-policy: HookSucceeded` — it runs after each successful sync and is cleaned up automatically.

No Terraform. No UI. Fully GitOps.

```
                ┌─────────────────────┐
                │  ArgoCD PostSync    │
                │  Provisioner Job    │
                └────────┬────────────┘
                         │ reads admin token
                         ▼
                ┌─────────────────────┐      writes scoped token
                │  Datastore API      │ ──────────────────────────► OpenBao
                │  (InfluxDB2/EMQX/   │                                │
                │   MongoDB)          │                                │ ESO syncs
                └─────────────────────┘                                ▼
                                                             K8s Secret in
                                                             consumer namespace
```

---

## InfluxDB2

### Credential bootstrapping (one-time manual)

The Helm chart requires `adminUser.existingSecret` to exist before the pod starts. ESO syncs this from OpenBao — but OpenBao must contain the values first.

```bash
# Run once before applying RootDatastores or adding the cluster to the ApplicationSet
bao kv put secret/<cluster>/influxdb2 \
  admin-password=<password> \
  admin-token=<token>
```

- `admin-password` — the admin UI login password. Any strong password (e.g., 20+ chars from a password manager). This is stored in OpenBao and never committed.
- `admin-token` — the operator API token used by the chart to authenticate initial setup calls. **Any string works** (InfluxDB2 accepts arbitrary token values, confirmed with 20-char passwords). Generate with: `openssl rand -base64 24 | tr -d '=+/'`

### Per-app token provisioning (PostSync Job)

**Pattern for each consuming app (e.g., Telegraf write token):**

```yaml
# gitops/k8s-manifests/<cluster>/influxdb2/provisioner-telegraf.yaml
---
apiVersion: batch/v1
kind: Job
metadata:
  name: influxdb2-provision-telegraf
  namespace: monitoring
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: provisioner
          image: curlimages/curl:latest
          env:
            - name: INFLUX_TOKEN
              valueFrom:
                secretKeyRef:
                  name: influxdb2
                  key: admin-token
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: openbao-provision-token   # scoped write token for provisioner
                  key: token
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              INFLUX_HOST="http://influxdb2.monitoring.svc.cluster.local"
              ORG="homelab"
              BUCKET="loxone"

              # Idempotency: check if token already exists by description
              EXISTING=$(curl -sf \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                "${INFLUX_HOST}/api/v2/authorizations" \
                | grep -c '"description":"telegraf-write"' || true)

              if [ "$EXISTING" -gt 0 ]; then
                echo "Token 'telegraf-write' already exists, skipping."
                exit 0
              fi

              # Get org ID
              ORG_ID=$(curl -sf \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                "${INFLUX_HOST}/api/v2/orgs?org=${ORG}" \
                | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

              # Get bucket ID
              BUCKET_ID=$(curl -sf \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                "${INFLUX_HOST}/api/v2/buckets?org=${ORG}&name=${BUCKET}" \
                | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

              # Create scoped write-only token
              RESULT=$(curl -sf -X POST \
                -H "Authorization: Token ${INFLUX_TOKEN}" \
                -H "Content-Type: application/json" \
                "${INFLUX_HOST}/api/v2/authorizations" \
                -d "{
                  \"description\": \"telegraf-write\",
                  \"orgID\": \"${ORG_ID}\",
                  \"permissions\": [{
                    \"action\": \"write\",
                    \"resource\": { \"type\": \"buckets\", \"id\": \"${BUCKET_ID}\", \"orgID\": \"${ORG_ID}\" }
                  }]
                }")

              NEW_TOKEN=$(echo "$RESULT" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

              # Write to OpenBao
              curl -sf -X POST \
                -H "X-Vault-Token: ${BAO_TOKEN}" \
                -H "Content-Type: application/json" \
                "http://vault.server3.home/v1/secret/data/<cluster>/telegraf" \
                -d "{\"data\": {\"influxdb2-token\": \"${NEW_TOKEN}\"}}"

              echo "Token provisioned and written to OpenBao."
```

**Key points:**
- The Job reads the admin token from the `influxdb2` K8s Secret (already synced by ESO)
- It writes the new token to OpenBao at `secret/<cluster>/telegraf` (or the consumer's path)
- It uses a **provisioner-specific OpenBao token** (`openbao-provision-token`) that has write access to `secret/data/<cluster>/*` — separate from the read-only ESO token
- The consumer app's `ExternalSecret` (e.g., in the `telegraf` namespace) picks up the new value on the next refresh cycle (default: 1h)

**Provisioner OpenBao token setup (one-time per cluster):**
```bash
# Create a write policy scoped to the cluster's secret path
bao policy write <cluster>-provisioner - <<'EOF'
path "secret/data/<cluster>/*" { capabilities = ["create", "update"] }
EOF

# Create a long-lived token for use in provisioner Jobs
bao token create -policy=<cluster>-provisioner -period=8760h -display-name="<cluster>-provisioner"
# Store the token: bao kv put secret/<cluster>/provisioner-token token=<value>
# Then create a K8s Secret or ExternalSecret named openbao-provision-token in the monitoring namespace
```

### InfluxDB2 API reference

| Operation | Method | Endpoint |
|-----------|--------|----------|
| List orgs | GET | `/api/v2/orgs` |
| List buckets | GET | `/api/v2/buckets` |
| Create bucket | POST | `/api/v2/buckets` |
| List authorizations (tokens) | GET | `/api/v2/authorizations` |
| Create authorization (token) | POST | `/api/v2/authorizations` |

All requests require `Authorization: Token <admin-token>` header.

---

## EMQX

EMQX has an HTTP management API on port 18083. The same PostSync Job pattern applies.

### Credential bootstrapping
```bash
bao kv put secret/<cluster>/emqx \
  dashboard-username=<user> \
  dashboard-password=<password>
```

### Per-app credential provisioning

```bash
# In the provisioner Job: create a scoped API user via EMQX HTTP API
# Basic auth with dashboard credentials

curl -sf -X POST \
  -u "${EMQX_USER}:${EMQX_PASS}" \
  -H "Content-Type: application/json" \
  "http://emqx.mqtt.svc.cluster.local:18083/api/v5/authentication/password_based:built_in_database/users" \
  -d '{
    "user_id": "telegraf",
    "password": "<generated-password>",
    "is_superuser": false
  }'
```

Useful endpoints:
- `GET /api/v5/authentication/password_based:built_in_database/users` — list users
- `POST /api/v5/authentication/password_based:built_in_database/users` — create user
- `DELETE /api/v5/authentication/password_based:built_in_database/users/{user_id}` — delete user

---

## MongoDB

MongoDB has two provisioning options. **Prefer Option B** for production workloads (native rotation).

### Option A: PostSync Job (same pattern as InfluxDB2/EMQX)

```bash
mongosh "mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PASS}@mongodb.mongodb.svc.cluster.local" \
  --eval '
    const db = connect("mongodb://localhost/admin");
    if (!db.getUser("app-user")) {
      db.createUser({
        user: "app-user",
        pwd: "'"${GENERATED_PASSWORD}"'",
        roles: [{ role: "readWrite", db: "myapp" }]
      });
    }
  '
```

### Option B: OpenBao Dynamic Database Secrets Engine (recommended)

OpenBao natively supports MongoDB as a dynamic secret engine. It creates short-lived credentials on demand and auto-rotates them — no provisioner Job needed.

```bash
# Enable the database engine
bao secrets enable database

# Configure the MongoDB connection (admin credentials stored in OpenBao)
bao write database/config/mongodb \
  plugin_name=mongodb-database-plugin \
  allowed_roles="app-role" \
  connection_url="mongodb://{{username}}:{{password}}@mongodb.<cluster>.svc.cluster.local:27017/admin" \
  username="root" \
  password="<mongo-root-password>"

# Create a role that generates scoped credentials
bao write database/roles/app-role \
  db_name=mongodb \
  creation_statements='{ "db": "myapp", "roles": [{ "role": "readWrite" }] }' \
  default_ttl="1h" \
  max_ttl="24h"
```

The ESO `ExternalSecret` then uses a `remoteRef` pointing to `database/creds/app-role`. ESO auto-renews before TTL expiry. The consuming app's K8s Secret is updated transparently.

```yaml
# ExternalSecret for dynamic MongoDB credentials
spec:
  data:
    - secretKey: username
      remoteRef:
        key: database/creds/app-role
        property: username
    - secretKey: password
      remoteRef:
        key: database/creds/app-role
        property: password
```

This is the cleanest solution for MongoDB: zero manual intervention after initial setup, automatic rotation, no provisioner Jobs.

---

## Adding a new consumer app: checklist

1. **Provisioner Job** — create `gitops/k8s-manifests/<cluster>/<datastore>/provisioner-<app>.yaml` with `PostSync` hook
2. **OpenBao path** — decide on path: `secret/<cluster>/<app>` (consistent with existing layout)
3. **ExternalSecret in consumer namespace** — create in `gitops/k8s-manifests/<cluster>/<app>/ExternalSecret.yaml` referencing the path the provisioner writes to
4. **Provisioner token** — ensure `openbao-provision-token` Secret exists in the provisioner's namespace with write access to `secret/data/<cluster>/*`
5. **Idempotency** — provisioner Job must check existence before creating (safe to re-run on every sync)
