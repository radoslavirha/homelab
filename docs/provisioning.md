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
- `serviceAccountName: provisioner` — the identity it logs in to OpenBao with. Datastore admin
  credentials still arrive by `secretKeyRef` (kubelet-injected, no RBAC needed)
- `automountServiceAccountToken: false` — the repo-wide default stays. The Job mounts a *projected*
  10-minute ServiceAccount token instead, used once to log in. It makes no K8s API calls and needs
  no RBAC and no `ca.crt`: OpenBao verifies the token itself
- All Jobs use `ghcr.io/radoslavirha/homelab-provisioner` — single image with `influx` CLI, `bao` CLI, `mongosh`, `curl`, `jq`. **Pinned by digest**, see below
- Idempotent — safe to re-run on every sync

### Provisioner Helm chart

Chart location: `gitops/helm-charts/provisioner/`

Added as a 4th `sources` entry in each datastore ApplicationSet. Per-cluster values live at `gitops/helm-values/<cluster>/provisioner/<datastore>.yaml`. To add a new resource, add an entry to the values file — no new Job YAML needed.

```yaml
# gitops/helm-values/server1/provisioner/influxdb2.yaml
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
          baoCluster: server1          # optional: override target OpenBao path prefix (default: global.cluster)
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

Built and pushed to `ghcr.io/radoslavirha/homelab-provisioner` via `.github/workflows/provisioner-image.yaml` on any change to `provisioner/Dockerfile`. The workflow publishes **two tags for the same digest**: `latest` and the full commit SHA.

**The chart pins the digest, not the tag** — `image.digest` in `gitops/helm-charts/provisioner/values.yaml`. `:latest` alone is not reproducible: PostSync Jobs on different days could pull different bytes, and a failed Job could not be reproduced from the manifest. The commit-SHA tag cannot be used instead, because it is the SHA of the commit that changes the Dockerfile and so is unknowable until after that commit exists.

After a rebuild, update the digest:

```bash
docker buildx imagetools inspect ghcr.io/radoslavirha/homelab-provisioner:latest
```

Then **sync each datastore app explicitly** — a hook-only change never shows as `OutOfSync` (the Jobs are deleted by `hook-delete-policy: HookSucceeded`, so there is nothing live to diff), and it will otherwise sit undeployed until some unrelated change forces a sync.

> **CLI versions must not trail the servers they talk to.** `ARG BAO_VERSION` should match the OpenBao server version. Note that OpenBao renamed its release assets between 2.5.3 and 2.6.2 — `bao_<v>_Linux_x86_64.tar.gz` became `openbao_<v>_linux_amd64.tar.gz`, though the binary inside is still `bao`. If a bump 404s, check the release asset names before assuming the version is wrong.

> **Rotation:** Scheduled credential rotation is not yet implemented. The provisioner writes each datastore credential once, and nothing re-writes it on a schedule.

---

## How a Job authenticates to OpenBao

Kubernetes auth, the same method ESO uses. Each Job exchanges its own ServiceAccount token for a
1-hour OpenBao token at login, so there is nothing to mint, store, rotate or expire.

```
ServiceAccount `provisioner` (ns iot, ns mongodb)
  → projected token, 600s, at /var/run/secrets/kubernetes.io/serviceaccount/token
    → bao write auth/kubernetes-server1/login role=provisioner jwt=@<that file>
      → OpenBao TokenReviews it against server1's API server
        → 1h token carrying the server1-provisioner policy
```

The login lives in `provisioner.baoPrelude`
([`_helpers.tpl`](../gitops/helm-charts/provisioner/templates/_helpers.tpl)) and runs before any
datastore is touched. The `bao token lookup` guard stays immediately after it: a login can succeed
and still hand back a token bound to the wrong policy.

**What this replaced, and why.** Until 2026-09-22 the Jobs read a hand-minted token out of KV via
ESO. `-period=8760h` was silently clamped by the token mount's `max_lease_ttl` of 768h, so the token
was minted for 32 days rather than a year and nothing renewed it — the cause of the 2026-09-06
outage. Kubernetes auth removes the whole class of problem.

**Setup is two things, both declarative:**

| | Where |
|---|---|
| ServiceAccount `provisioner`, `automountServiceAccountToken: false` | `gitops/k8s-manifests/server1/{iot,mongodb}/ServiceAccount.provisioner.yaml` |
| OpenBao role `provisioner` on `auth/kubernetes-<cluster>` | `kubernetes_provisioner_roles` in [`iac/clusters/server3/vault-config/main.tf`](../iac/clusters/server3/vault-config/main.tf) → [`modules/vault-config/kubernetes.tf`](../iac/modules/vault-config/kubernetes.tf) |

The `<cluster>-provisioner` **policy** is still created by the CLI, unchanged
([`docs/iac.md`](iac.md) § 3.e). `read` and `patch` in it are not optional: the Jobs call
`bao kv get` to decide whether a credential already exists before rotating it, so a
create/update-only policy authenticates fine and then fails partway through a run.

The auth **mount** itself (`auth/kubernetes-<cluster>`, its config and the `external-secrets` role)
also stays on the CLI. ESO must be able to log in before the first Application carrying an
ExternalSecret syncs, and the `vault-config` Terraform stage runs after that point — see the header
of `modules/vault-config/kubernetes.tf`.

> **A sealed OpenBao blocks a sync.** OpenBao reseals on reboot and needs three unseal keys by hand.
> A Job against a sealed OpenBao now fails at the login rather than at `bao token lookup` — one line
> earlier, still before any datastore call. **Do not sync a datastore Application while OpenBao is
> sealed.**

> **There is no cross-cluster write path, and there never was a working one.** Earlier revisions of this document granted `secret/data/server3/<cluster>-influxdb2-grafana` so the InfluxDB2 provisioner could write the Grafana datasource token into server3's tree. No provisioner token has ever been allowed to write there — each is scoped to `secret/data/<own cluster>/*` — so every run 403'd silently while Grafana kept working off a value seeded at bootstrap. The token is now written to the provisioner's **own** cluster tree as `influxdb2-grafana`, and server3's ESO reads it from there (`key: server1/influxdb2-grafana`). See [`gitops/helm-values/server1/provisioner/influxdb2.yaml`](../gitops/helm-values/server1/provisioner/influxdb2.yaml). Do not re-add the grant.

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

Declared in [`gitops/helm-values/server1/provisioner/influxdb2.yaml`](../gitops/helm-values/server1/provisioner/influxdb2.yaml), rendered by the provisioner chart.

**Job `influxdb2-provision-loxone`** (wave 0):

1. Ensures `loxone` bucket exists (14-day retention)
2. Ensures `loxone_downsample` bucket exists (infinite retention)
3. Ensures Flux task `Downsample Loxone` exists (10m aggregation loxone → loxone_downsample)
4. Checks if token `server1-grafana-read` already exists in OpenBao at `secret/server1/influxdb2-grafana` → skip if yes
5. Creates a read-only token scoped to `loxone` + `loxone_downsample` buckets (`readBuckets`)
6. Writes `token` to OpenBao: `secret/server1/influxdb2-grafana` — this cluster's **own** tree

Note: this used to target `secret/server3/server1-influxdb2-grafana` via a `baoCluster: server3` override, which **no provisioner token has ever been allowed to write** — each is scoped to `secret/data/<own cluster>/*`. Every run 403'd silently while Grafana kept working off a value seeded at bootstrap. server3's ESO reads `key: server1/influxdb2-grafana` ([`ExternalSecret.server1.influxdb2.yaml`](../gitops/k8s-manifests/server3/grafana/ExternalSecret.server1.influxdb2.yaml)), so consuming it from the writer's own tree works identically. Do not reintroduce `baoCluster` here.

**Job `influxdb2-provision-telegraf`** (wave 1, after loxone):

1. Checks if token with description `telegraf-write` already exists → skip if yes
2. Creates a write-only token scoped to the `loxone` bucket
3. Writes `token` to OpenBao: `secret/server1/telegraf-influxdb2`

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

Declared in [`gitops/helm-values/server1/provisioner/emqx.yaml`](../gitops/helm-values/server1/provisioner/emqx.yaml), rendered by the provisioner chart.

Each job group:

1. Ensures the built-in database authenticator is configured (idempotent)
2. Checks if the MQTT user already exists (via API or OpenBao) → skip if yes
3. Generates a random 24-char password and creates (or rotates) the user
4. Writes `username` + `password` to the service-owned OpenBao path

`telegraf` job (idempotencyStrategy: `api-check`) → `secret/server1/telegraf-mqtt`
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

- `secret/server1/production/miot-bridge-api-emqx` → `mqtt-username`, `mqtt-password`
- `secret/server1/sandbox/miot-bridge-api-emqx` → `mqtt-username`, `mqtt-password`
- `secret/server1/production/miot-bridge-api-mongodb` → `mongodb-database`, `mongodb-username`, `mongodb-password`
- `secret/server1/sandbox/miot-bridge-api-mongodb` → `mongodb-database`, `mongodb-username`, `mongodb-password`

### EMQX MQTT user (PostSync Job)

Declared in [`gitops/helm-values/server1/provisioner/emqx.yaml`](../gitops/helm-values/server1/provisioner/emqx.yaml) under `emqx.jobs.miot-bridge-production` and `emqx.jobs.miot-bridge-sandbox`. Runs in `iot` namespace (where the `provisioner` ServiceAccount and `emqx-credentials` already exist):

1. Checks if `mqtt-username` already exists in `secret/server1/{env}/miot-bridge-api-emqx` → skip if yes (idempotencyStrategy: `bao-check`)
2. Generates a random 24-char password and creates (or rotates) MQTT user `miot-bridge-{env}`
3. Writes `mqtt-username` + `mqtt-password` to OpenBao at `secret/server1/{env}/miot-bridge-api-emqx`

### MongoDB database + user (PostSync Job)

Declared in [`gitops/helm-values/server1/provisioner/mongodb.yaml`](../gitops/helm-values/server1/provisioner/mongodb.yaml) under `mongodb.jobs.miot-bridge-production` and `mongodb.jobs.miot-bridge-sandbox`. Runs in `mongodb` namespace (where `mongodb` root password secret exists):

1. Checks if `mongodb-password` already exists in `secret/server1/{env}/miot-bridge-api-mongodb` → skip if yes
2. Generates a random 24-char password, creates (or rotates) MongoDB user `miot-bridge-{env}` in database `miot-bridge-{env}`
3. Writes `mongodb-database` + `mongodb-username` + `mongodb-password` to OpenBao at `secret/server1/{env}/miot-bridge-api-mongodb`

> **Note:** the `provisioner` ServiceAccount must exist in both `iot` and `mongodb`, and the OpenBao
> role must bind both namespaces. The `iot` copy is deployed by `IotInfra`, the `mongodb` copy by the
> MongoDB ApplicationSet. In `iot` that is a cross-Application dependency — the ServiceAccount comes
> from `IotInfra` while the Jobs come from `EMQX` and `InfluxDB2` — exactly as the token Secret it
> replaced did.

### No manual seeding required

Unlike InfluxDB2/EMQX/MongoDB root credentials, `miot-bridge-api` credentials are **entirely auto-generated** by the provisioner Jobs. No `bao kv put` step is needed for these paths.

---

## qr-manager-api

`qr-manager-api` needs scoped MongoDB credentials. Provisioned by a PostSync Job and written to OpenBao. ExternalSecret in the `production` and `sandbox` namespaces then pulls them.

OpenBao KV layout:

- `secret/server1/production/qr-manager-api-mongodb` → `mongodb-database`, `mongodb-username`, `mongodb-password`
- `secret/server1/sandbox/qr-manager-api-mongodb` → `mongodb-database`, `mongodb-username`, `mongodb-password`

### MongoDB database + user (PostSync Job)

Declared in [`gitops/helm-values/server1/provisioner/mongodb.yaml`](../gitops/helm-values/server1/provisioner/mongodb.yaml) under `mongodb.jobs.qr-manager-production` and `mongodb.jobs.qr-manager-sandbox`. Runs in `mongodb` namespace:

1. Checks if `mongodb-password` already exists in `secret/server1/{env}/qr-manager-api-mongodb` → skip if yes
2. Generates a random 24-char password, creates (or rotates) MongoDB user `qr-manager-{env}` in database `qr-manager-{env}`
3. Writes `mongodb-database` + `mongodb-username` + `mongodb-password` to OpenBao at `secret/server1/{env}/qr-manager-api-mongodb`

### No manual seeding required

`qr-manager-api` MongoDB credentials are **entirely auto-generated** by the provisioner Jobs. No `bao kv put` step is needed for these paths.

---

## Adding a new consumer app: checklist

1. **Provisioner values** — add a job entry to `gitops/helm-values/<cluster>/provisioner/{influxdb2,emqx,mongodb}.yaml` for each resource the app needs. No new Job YAML file required.
2. **OpenBao path** — choose a service-owned path such as `secret/<cluster>/<env>/<app>/<service>` and set it as `baoPath` in the values entry.
3. **ExternalSecret in consumer namespace** — referencing the path the provisioner writes to.
4. **Provisioner identity** — only if the app introduces a **new namespace** for provisioner Jobs: add a `ServiceAccount.provisioner.yaml` there, and add the namespace to `kubernetes_provisioner_roles` in `iac/clusters/server3/vault-config/main.tf`. Nothing to do for `iot` or `mongodb`.
5. **Idempotency** — the chart handles this; choose `idempotencyStrategy: bao-check` (skip if path already in OpenBao) or `api-check` (skip if resource already exists in the service API).

---

## Troubleshooting

### Provisioner Jobs fail to log in to OpenBao

Symptom, from a Job's logs — the first thing the Job does:

```text
ERROR: Kubernetes auth login to https://vault.server3.homelab.irha.cz failed -- refusing to touch any datastore.
```

Nothing has been touched: the login is the first statement in `provisioner.baoPrelude` and the Job
exits before any datastore call. Work down this list.

1. **Is OpenBao sealed?** `bao status`. It reseals on every server3 reboot and needs three unseal
   keys by hand. Most likely cause.
2. **Does the ServiceAccount exist in the Job's namespace?** `kubectl get sa provisioner -n <ns>`.
   If it is missing the pod never starts at all —
   `error looking up service account <ns>/provisioner` on the Job, and no pod is created.
3. **Does the role bind that namespace?**
   `bao read auth/kubernetes-<cluster>/role/provisioner` — check `bound_service_account_names` and
   `bound_service_account_namespaces`. Adding a namespace means editing
   `kubernetes_provisioner_roles` and applying the `vault-config` stage, not a CLI write.
4. **Is the mount healthy?** `bao read auth/kubernetes-<cluster>/config` —
   `token_reviewer_jwt_set` must be `true`. That reviewer JWT is created by hand
   (`docs/iac.md` § 3.a) and is not managed by Terraform.

Reproduce the login by hand without running a Job, from the namespace in question:

```bash
kubectl --context admin@<cluster> run bao-login-check -n <ns> --rm --restart=Never --attach=true \
  --image=ghcr.io/radoslavirha/homelab-provisioner:latest \
  --overrides='{"spec":{"serviceAccountName":"provisioner","automountServiceAccountToken":false,
    "volumes":[{"name":"t","projected":{"sources":[{"serviceAccountToken":{"path":"token","expirationSeconds":600}}]}}],
    "containers":[{"name":"c","image":"ghcr.io/radoslavirha/homelab-provisioner:latest",
      "volumeMounts":[{"name":"t","mountPath":"/var/run/secrets/kubernetes.io/serviceaccount"}],
      "command":["/bin/sh","-c"],"args":["bao write -address=https://vault.server3.homelab.irha.cz -field=token auth/kubernetes-<cluster>/login role=provisioner jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token"]}]}}'
```

### Provisioner Jobs fail with `403 permission denied`

Symptom, from a Job's logs, *after* a successful login:

```text
URL: GET https://vault.server3.homelab.irha.cz/v1/sys/internal/ui/mounts/secret/<cluster>/<env>/<app>
Code: 403. Errors:
* permission denied
```

That URL is the `bao kv` preflight mount lookup. Since the login now mints the token seconds
earlier, an expired-token cause is gone — this is a **policy** problem. Check what the login
actually handed back, using the reproduce-by-hand pod above followed by
`bao token lookup -format=json | jq .data.policies`: it must contain `<cluster>-provisioner`. If it
contains only `default`, `token_policies` on the role is wrong. If the policy is attached but a
specific path 403s, read the policy — `read` and `patch` on `secret/data/<cluster>/*` and
`read`/`list` on `secret/metadata/<cluster>/*` are all required.

A provisioner is scoped to its **own** cluster tree. `secret/server2/*` from a server1 Job is denied
by design, not a misconfiguration.

**Recovery:**

1. Stop the retries first — a Job that reaches the datastore before failing rotates a password it
   cannot persist. Delete the failed Jobs (ArgoCD recreates them on the next sync).
2. Fix the role or policy, then re-sync the Application. There is no token to re-mint.
3. Delete any **stale** app secrets in OpenBao — paths whose stored password no longer matches the
   datastore because a previous run rotated it. `bao-check` treats an existing path as "already
   provisioned" and skips, so a stale path never self-heals.

Both guards in `provisioner.baoPrelude` fail closed: the login aborts the Job, and the
`bao token lookup` after it catches a login that succeeded with the wrong policy. Neither reaches a
datastore.
