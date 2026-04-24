# Dynamic Credential Provisioning

This document describes the strategy for provisioning application-level credentials (tokens, users, passwords) for datastores — without any Terraform stage or manual UI clicks.

## Problem

Datastores like InfluxDB2, EMQX, and MongoDB need per-app credentials scoped to a specific purpose (e.g., Telegraf gets a write-only token for the `loxone` bucket). The root admin credential bootstraps the datastore, but connected apps should never use admin credentials.

Manual workflows — log in to UI, create token, copy to Vault, update consumer secret — break GitOps: credentials are not reproducible, rotation is painful, and adding a new app requires human intervention.

## Solution: PostSync provisioner Jobs

Each app that needs scoped credentials gets a **PostSync Job** that runs after every ArgoCD sync. The Job is idempotent: it checks whether the credential already exists and skips if so. On the very first sync it creates the credential and writes it to OpenBao. Subsequent syncs are no-ops.

```
ArgoCD syncs app
  → PostSync Job runs
    → checks if credential exists in source system
      → if yes: exit 0 (no-op)
      → if no:  create credential in source system
                → write to OpenBao
                  → ESO syncs K8s Secret from OpenBao
```

Key properties of every provisioner Job:
- `automountServiceAccountToken: false` — makes no K8s API calls
- No `serviceAccountName` — accesses secrets via `secretKeyRef` (kubelet-injected, no RBAC needed)
- Only `curl` and `jq` required — no `kubectl`
- Idempotent — safe to re-run on every sync

> **Rotation:** Scheduled credential rotation is not yet implemented. See [`docs/superpowers/plans/2026-04-22-credential-rotation.md`](superpowers/plans/2026-04-22-credential-rotation.md) for the implementation plan.

---

## Shared provisioner token (IotInfra)

Provisioner Jobs need a long-lived OpenBao token with write access to write credentials back after calling each datastore's API. This token is stored in OpenBao and synced into the `iot` namespace as a Secret by the `IotInfra` ApplicationSet — which runs at `sync-wave: -1` so it is available before InfluxDB2 and EMQX sync.

```
gitops/k8s-manifests/server2/iot/ExternalSecret.provisioner-token.yaml
  → Secret: openbao-provision-token (namespace: iot)
  → remoteRef: secret/server2/provisioner-token → token
```

**One-time setup (per cluster):**
```bash
bao policy write server2-provisioner - <<'EOF'
path "secret/data/server2/*" { capabilities = ["create", "read", "update", "patch"] }
path "secret/metadata/server2/*" { capabilities = ["read", "list"] }
EOF

TOKEN=$(bao token create \
  -policy=server2-provisioner \
  -period=8760h \
  -display-name="server2-provisioner" \
  -field=token)

bao kv put secret/server2/provisioner-token token="${TOKEN}"
```

---

## InfluxDB2

### Admin credential bootstrapping (one-time manual)

The Helm chart requires `adminUser.existingSecret` to exist before the pod starts. ESO syncs this from OpenBao — but OpenBao must contain the values first.

```bash
bao kv put secret/<cluster>/influxdb2 \
  admin-password=<password> \
  admin-token=<token>
```

- `admin-password` — the admin UI login password. Any strong password (20+ chars).
- `admin-token` — the operator API token used by the chart. **Any string works** (InfluxDB2 accepts arbitrary token values). Generate with: `openssl rand -base64 24 | tr -d '=+/'`

### Telegraf write token (PostSync Job — create-only)

[`gitops/k8s-manifests/server2/influxdb2/provisioner-telegraf.yaml`](../gitops/k8s-manifests/server2/influxdb2/provisioner-telegraf.yaml)

1. Ensures the `loxone` bucket exists (idempotent)
2. Checks if a token with description `telegraf-write` already exists → skip if yes
3. Creates a write-only token scoped to the `loxone` bucket
4. Writes `token` to OpenBao: `secret/server2/telegraf-influxdb2`

Consumed by `ExternalSecret telegraf-influxdb2-credentials` in the `telegraf` namespace.

### InfluxDB2 API reference

| Operation | Method | Endpoint |
|-----------|--------|----------|
| List orgs | GET | `/api/v2/orgs` |
| List buckets | GET | `/api/v2/buckets` |
| Create bucket | POST | `/api/v2/buckets` |
| List authorizations (tokens) | GET | `/api/v2/authorizations` |
| Create authorization (token) | POST | `/api/v2/authorizations` |
| Delete authorization (token) | DELETE | `/api/v2/authorizations/{id}` |

All requests require `Authorization: Token <admin-token>` header.

---

## EMQX

EMQX has an HTTP management API on port 18083.

### Dashboard credential bootstrapping (one-time manual)

```bash
bao kv put secret/<cluster>/emqx \
  dashboard-username=<user> \
  dashboard-password=<password>
```

### Telegraf MQTT user (PostSync Job — create-only)

[`gitops/k8s-manifests/server2/emqx/provisioner-telegraf.yaml`](../gitops/k8s-manifests/server2/emqx/provisioner-telegraf.yaml)

1. Ensures the built-in database authenticator is configured (idempotent)
2. Checks if user `telegraf` already exists (HTTP 200) → skip if yes
3. Generates a random 24-char password and creates the MQTT user
4. Writes `username` + `password` to OpenBao: `secret/server2/telegraf-mqtt`

Consumed by `ExternalSecret telegraf-mqtt-credentials` in the `telegraf` namespace.

### EMQX API reference

| Operation | Method | Endpoint |
|-----------|--------|----------|
| List authenticators | GET | `/api/v5/authentication` |
| Create authenticator | POST | `/api/v5/authentication` |
| Get user | GET | `/api/v5/authentication/password_based:built_in_database/users/{id}` |
| Create user | POST | `/api/v5/authentication/password_based:built_in_database/users` |
| Update user password | PUT | `/api/v5/authentication/password_based:built_in_database/users/{id}` |
| Delete user | DELETE | `/api/v5/authentication/password_based:built_in_database/users/{id}` |

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

## miot-bridge-api-iot

`miot-bridge-api-iot` needs scoped credentials in both EMQX (MQTT) and MongoDB. Both are provisioned by PostSync Jobs and written to OpenBao. ExternalSecrets in the `production` and `sandbox` namespaces then pull them.

OpenBao KV layout:

- `secret/server2/production/miot-bridge-api-emqx` → `mqtt-username`, `mqtt-password`
- `secret/server2/sandbox/miot-bridge-api-iot/mqtt` → `mqtt-username`, `mqtt-password`
- `secret/server2/production/miot-bridge-api-mongodb` → `mongodb-database`, `mongodb-username`, `mongodb-password`
- `secret/server2/sandbox/miot-bridge-api-iot/mongodb` → `mongodb-database`, `mongodb-username`, `mongodb-password`

### EMQX MQTT user (PostSync Job)

[`gitops/k8s-manifests/server2/emqx/provisioner-miot-bridge-production.yaml`](../gitops/k8s-manifests/server2/emqx/provisioner-miot-bridge-production.yaml)
[`gitops/k8s-manifests/server2/emqx/provisioner-miot-bridge-sandbox.yaml`](../gitops/k8s-manifests/server2/emqx/provisioner-miot-bridge-sandbox.yaml)

Run in `iot` namespace (where `openbao-provision-token` and `emqx-credentials` already exist):

1. Checks if `mqtt-username` already exists in `secret/server2/{env}/miot-bridge-api-iot/mqtt` → skip if yes
2. Generates a random 24-char password and creates (or rotates) MQTT user `miot-bridge-{env}`
3. Writes `mqtt-username` + `mqtt-password` to OpenBao via `POST` on a service-owned path (no cross-service merge needed)

### MongoDB database + user (PostSync Job)

[`gitops/k8s-manifests/server2/mongodb/provisioner-miot-bridge-production.yaml`](../gitops/k8s-manifests/server2/mongodb/provisioner-miot-bridge-production.yaml)
[`gitops/k8s-manifests/server2/mongodb/provisioner-miot-bridge-sandbox.yaml`](../gitops/k8s-manifests/server2/mongodb/provisioner-miot-bridge-sandbox.yaml)

Run in `mongodb` namespace (where `mongodb` root password secret exists):

1. Checks if `mongodb-password` already exists in `secret/server2/{env}/miot-bridge-api-iot/mongodb` → skip if yes
2. Generates a random 24-char password, creates (or rotates) MongoDB user `miot-bridge-{env}` in database `miot-bridge-{env}`
3. Writes `mongodb-database` + `mongodb-username` + `mongodb-password` to OpenBao via `POST` on a service-owned path

> **Note:** The provisioner token `openbao-provision-token` must exist in both `iot` and `mongodb` namespaces. The `iot` copy is deployed by `IotInfra`. The `mongodb` copy is deployed by the MongoDB ApplicationSet via [`gitops/k8s-manifests/server2/mongodb/ExternalSecret.provisioner-token.yaml`](../gitops/k8s-manifests/server2/mongodb/ExternalSecret.provisioner-token.yaml).

### No manual seeding required

Unlike InfluxDB2/EMQX/MongoDB root credentials, `miot-bridge-api-iot` credentials are **entirely auto-generated** by the provisioner Jobs. No `bao kv put` step is needed for these paths.

---

## Adding a new consumer app: checklist

1. **Provisioner Job** — create `gitops/k8s-manifests/<cluster>/<datastore>/provisioner-<app>.yaml` with `PostSync` hook annotation
2. **OpenBao path** — service-owned path such as `secret/<cluster>/<env>/<app>/<service>`
3. **ExternalSecret in consumer namespace** — referencing the path the provisioner writes to
4. **Provisioner token** — ensure `openbao-provision-token` Secret exists in the provisioner’s namespace (deployed by `IotInfra`-equivalent ApplicationSet)
5. **Idempotency** — provisioner Job must check existence before creating (safe to re-run on every sync)
