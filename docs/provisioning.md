# Dynamic Credential Provisioning

This document describes the strategy for provisioning application-level credentials (tokens, users, passwords) for datastores — without any Terraform stage or manual UI clicks.

## Problem

Datastores like InfluxDB2, EMQX, and MongoDB need per-app credentials scoped to a specific purpose (e.g., Telegraf gets a write-only token for the `loxone` bucket). The root admin credential bootstraps the datastore, but connected apps should never use admin credentials.

Manual workflows — log in to UI, create token, copy to Vault, update consumer secret — break GitOps: credentials are not reproducible, rotation is painful, and adding a new app requires human intervention.

## Solution: PostSync provisioner Jobs (Helm chart)

Each app that needs scoped credentials declares what it needs in the **provisioner Helm chart** values. The chart renders PostSync Jobs — one per named job group — that run after every ArgoCD sync. Each Job is idempotent: it checks whether the credential already exists and skips if so. On first sync it creates the credential and writes it to OpenBao. Subsequent syncs are no-ops.

```
ArgoCD syncs app
  → PostSync Job runs
    → checks if credential exists in source system
      → if yes: exit 0 (no-op)
      → if no:  create credential in source system
                → write to OpenBao (bao kv put)
                  → ESO syncs K8s Secret from OpenBao
```

Key properties of every provisioner Job:
- `automountServiceAccountToken: false` — makes no K8s API calls
- No `serviceAccountName` — accesses secrets via `secretKeyRef` (kubelet-injected, no RBAC needed)
- All Jobs use `ghcr.io/radoslavirha/homelab-provisioner` — single image with `influx` CLI, `bao` CLI, `mongosh`, `curl`, `jq`
- Idempotent — safe to re-run on every sync

### Provisioner Helm chart

Chart location: `gitops/helm-charts/provisioner/`

Added as a 4th `sources` entry in each datastore ApplicationSet. Per-cluster values live at `gitops/helm-values/<cluster>/provisioner/<datastore>.yaml`. To add a new resource, add an entry to the values file — no new Job YAML needed.

```yaml
# gitops/helm-values/server2/provisioner/influxdb2.yaml
influxdb2:
  jobs:
    my-new-app:              # → renders Job: influxdb2-provision-my-new-app
      syncWave: "1"
      buckets:
        - name: my-bucket
          retentionSeconds: 0
      tokens:
        - description: my-app-write
          writeBucket: my-bucket       # optional: grant write access to a bucket
          readBuckets:                 # optional: grant read access to one or more buckets
            - my-bucket
          baoPath: my-app/influxdb2
          baoKey: token
          baoCluster: server2          # optional: override target OpenBao path prefix (default: global.cluster)
                                       # use baoCluster: server3 when a credential is consumed by server3 ESO
```

**Token fields reference:**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `description` | yes | — | InfluxDB2 authorization description (used as idempotency key) |
| `writeBucket` | no | — | Grant write access to this bucket |
| `readBuckets` | no | `[]` | Grant read access to these buckets |
| `baoPath` | yes | — | OpenBao KV path suffix: `secret/<baoCluster>/<baoPath>` |
| `baoKey` | no | `token` | Key name written to OpenBao |
| `baoCluster` | no | `global.cluster` | Override the cluster prefix in the OpenBao path. Use `server3` when the token is consumed by server3 ESO. |

### Provisioner image

`provisioner/Dockerfile` — `debian:bookworm-slim` base with all tools installed via official package repos:

- `influx` CLI (InfluxData deb repo) — bucket, task, auth operations
- `bao` CLI (OpenBao GitHub release) — all OpenBao writes (`bao kv put`)
- `mongosh` (MongoDB deb repo) — database and user operations
- `curl` + `jq` — EMQX REST API (no remote CLI exists for EMQX)

Built and pushed to `ghcr.io/radoslavirha/homelab-provisioner` via `.github/workflows/provisioner-image.yaml` on any change to `provisioner/Dockerfile`.

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
path "secret/data/server2/*" { capabilities = ["create", "update"] }
path "secret/data/server3/influxdb2-grafana" { capabilities = ["create", "update"] }
EOF

TOKEN=$(bao token create \
  -policy=server2-provisioner \
  -period=8760h \
  -display-name="server2-provisioner" \
  -field=token)

bao kv put secret/server2/provisioner-token token="${TOKEN}"
```

> **Consumer-scoped paths:** Secrets are organised by who reads them, not who writes them. The `server3/influxdb2-grafana` path is written by the server2 provisioner but lives under `server3/` because it is consumed by server3 ESO. The policy grants exactly this one cross-cluster write path — no broader access.

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

### Loxone buckets + task + Telegraf write token (PostSync Jobs)

Declared in [`gitops/helm-values/server2/provisioner/influxdb2.yaml`](../gitops/helm-values/server2/provisioner/influxdb2.yaml), rendered by the provisioner chart.

**Job `influxdb2-provision-loxone`** (wave 0):

1. Ensures `loxone` bucket exists (14-day retention)
2. Ensures `loxone_downsample` bucket exists (infinite retention)
3. Ensures Flux task `Downsample Loxone` exists (10m aggregation loxone → loxone_downsample)
4. Checks if token `grafana-read` already exists in OpenBao at `secret/server3/influxdb2-grafana` → skip if yes
5. Creates a read-only token scoped to `loxone` + `loxone_downsample` buckets (`readBuckets`)
6. Writes `token` to OpenBao: `secret/server3/influxdb2-grafana` (consumed by server3 Grafana)

Note: token written to a server3 path using `baoCluster: server3` in the provisioner values — see provisioner template `baoCluster` field.

**Job `influxdb2-provision-telegraf`** (wave 1, after loxone):

1. Checks if token with description `telegraf-write` already exists → skip if yes
2. Creates a write-only token scoped to the `loxone` bucket
3. Writes `token` to OpenBao: `secret/server2/telegraf-influxdb2`

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

### MQTT users (PostSync Jobs)

Declared in [`gitops/helm-values/server2/provisioner/emqx.yaml`](../gitops/helm-values/server2/provisioner/emqx.yaml), rendered by the provisioner chart.

Each job group:

1. Ensures the built-in database authenticator is configured (idempotent)
2. Checks if the MQTT user already exists (via API or OpenBao) → skip if yes
3. Generates a random 24-char password and creates (or rotates) the user
4. Writes `username` + `password` to the service-owned OpenBao path

`telegraf` job (idempotencyStrategy: `api-check`) → `secret/server2/telegraf-mqtt`
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

## miot-bridge-api

`miot-bridge-api` needs scoped credentials in both EMQX (MQTT) and MongoDB. Both are provisioned by PostSync Jobs and written to OpenBao. ExternalSecrets in the `production` and `sandbox` namespaces then pull them.

OpenBao KV layout:

- `secret/server2/production/miot-bridge-api-emqx` → `mqtt-username`, `mqtt-password`
- `secret/server2/sandbox/miot-bridge-api-emqx` → `mqtt-username`, `mqtt-password`
- `secret/server2/production/miot-bridge-api-mongodb` → `mongodb-database`, `mongodb-username`, `mongodb-password`
- `secret/server2/sandbox/miot-bridge-api-mongodb` → `mongodb-database`, `mongodb-username`, `mongodb-password`

### EMQX MQTT user (PostSync Job)

Declared in [`gitops/helm-values/server2/provisioner/emqx.yaml`](../gitops/helm-values/server2/provisioner/emqx.yaml) under `emqx.jobs.miot-bridge-production` and `emqx.jobs.miot-bridge-sandbox`. Runs in `iot` namespace (where `openbao-provision-token` and `emqx-credentials` already exist):

1. Checks if `mqtt-username` already exists in `secret/server2/{env}/miot-bridge-api-emqx` → skip if yes (idempotencyStrategy: `bao-check`)
2. Generates a random 24-char password and creates (or rotates) MQTT user `miot-bridge-{env}`
3. Writes `mqtt-username` + `mqtt-password` to OpenBao at `secret/server2/{env}/miot-bridge-api-emqx`

### MongoDB database + user (PostSync Job)

Declared in [`gitops/helm-values/server2/provisioner/mongodb.yaml`](../gitops/helm-values/server2/provisioner/mongodb.yaml) under `mongodb.jobs.miot-bridge-production` and `mongodb.jobs.miot-bridge-sandbox`. Runs in `mongodb` namespace (where `mongodb` root password secret exists):

1. Checks if `mongodb-password` already exists in `secret/server2/{env}/miot-bridge-api-mongodb` → skip if yes
2. Generates a random 24-char password, creates (or rotates) MongoDB user `miot-bridge-{env}` in database `miot-bridge-{env}`
3. Writes `mongodb-database` + `mongodb-username` + `mongodb-password` to OpenBao at `secret/server2/{env}/miot-bridge-api-mongodb`

> **Note:** The provisioner token `openbao-provision-token` must exist in both `iot` and `mongodb` namespaces. The `iot` copy is deployed by `IotInfra`. The `mongodb` copy is deployed by the MongoDB ApplicationSet via [`gitops/k8s-manifests/server2/mongodb/ExternalSecret.provisioner-token.yaml`](../gitops/k8s-manifests/server2/mongodb/ExternalSecret.provisioner-token.yaml).

### No manual seeding required

Unlike InfluxDB2/EMQX/MongoDB root credentials, `miot-bridge-api` credentials are **entirely auto-generated** by the provisioner Jobs. No `bao kv put` step is needed for these paths.

---

## Adding a new consumer app: checklist

1. **Provisioner values** — add a job entry to `gitops/helm-values/<cluster>/provisioner/{influxdb2,emqx,mongodb}.yaml` for each resource the app needs. No new Job YAML file required.
2. **OpenBao path** — choose a service-owned path such as `secret/<cluster>/<env>/<app>/<service>` and set it as `baoPath` in the values entry.
3. **ExternalSecret in consumer namespace** — referencing the path the provisioner writes to.
4. **Provisioner token** — ensure `openbao-provision-token` Secret exists in the provisioner’s namespace (deployed by `IotInfra`-equivalent ApplicationSet). The MongoDB provisioner runs in `mongodb` namespace and needs its own copy via `ExternalSecret.provisioner-token.yaml`.
5. **Idempotency** — the chart handles this; choose `idempotencyStrategy: bao-check` (skip if path already in OpenBao) or `api-check` (skip if resource already exists in the service API).
