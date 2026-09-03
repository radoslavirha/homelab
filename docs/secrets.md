# Secrets Reference

All application secrets are stored in OpenBao (KV v2, mount `secret`) on the **server3** cluster and synced to all clusters via External Secrets Operator (ESO).

This document is the single source of truth for **what must exist in OpenBao before each deployment stage**.  
Every stage in `docs/iac.md` and `gitops/README.md` that requires secrets links here.

---

## Quick reference — all paths

| OpenBao path | Keys | Required before | Cluster |
|---|---|---|---|
| `secret/server3/argocd` | `adminPasswordHash` | ArgoCD install (`apps` stage) | server3 |
| `secret/<cluster>/cert-manager` | `api-token` | infra stage — cert-manager | any |
| `secret/<cluster>/external-dns` | `api-key` | gateway stage | any |
| `secret/server3/grafana` | `admin-user`, `admin-password` | observability stage | server3 |
| `secret/server3/grafana-image-renderer` | `token` | *optional — image-renderer pods only* | server3 |
| `secret/<cluster>/influxdb2` | `admin-password`, `admin-token` | iot stage | any |
| `secret/<cluster>/emqx` | `dashboard-username`, `dashboard-password` | iot stage | any |
| `secret/<cluster>/mongodb` | `root-password` | databases stage | any |
| `secret/otel-gateway/auth-token` | `token` | observability stage | server1, server2 |
| `secret/<cluster>/influxdb2-grafana` | `token` | *provisioned at runtime* | server1, server2 |

`<cluster>` is the short cluster name: `server2`, `server3`, etc.

---

## How to open an OpenBao session

### When vault.server3.homelab.irha.cz is reachable (DNS + Traefik running)

```bash
export BAO_ADDR=https://vault.server3.homelab.irha.cz
bao login <root-token>
```

### Before Traefik is up — use port-forward

```bash
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
bao login <root-token>
```

---

## server3/argocd

**Required before:** `iac/clusters/server3/apps` (`terraform apply`)

ArgoCD admin password stored as a bcrypt hash to avoid Terraform re-hashing on every apply.

```bash
# Generate bcrypt hash (htpasswd ships with macOS)
htpasswd -bnBC 10 "" YOUR_PASSWORD | tr -d ':\n'

# Store in OpenBao
bao kv put secret/server3/argocd adminPasswordHash='$2a$10$...'

# Verify
bao kv get secret/server3/argocd
```

---

## server3/grafana

**Required before:** observability stage (`RootObservability.yaml` applied)

Grafana references `existingSecret: grafana-admin`. ESO syncs this secret from OpenBao before the pod starts.

```bash
bao kv put secret/server3/grafana \
  admin-user=admin \
  admin-password=<strong-password>

# Verify
bao kv get secret/server3/grafana
```

---

## server3/grafana-image-renderer

**Required before:** nothing — optional. Grafana starts fine without it; only the
`grafana-image-renderer` Deployment's pods (dashboard/panel PNG export, used by the
`get_panel_image` MCP tool) depend on it. Missing secret means those pods
CrashLoop/fail to authenticate, nothing else.

Authenticates the Grafana pod to its own image-renderer pod — both already restricted
to each other by a NetworkPolicy, not a credential with external reach. Value can be
regenerated freely any time; both pods just need to restart afterwards to pick it up.

```bash
bao kv put secret/server3/grafana-image-renderer token=$(python3 -c "import secrets; print(secrets.token_urlsafe(30))")

# Verify (don't print the value — just confirm the key exists)
bao kv get -field=token secret/server3/grafana-image-renderer | wc -c
```

---

## \<cluster\>/cert-manager

**Required before:** infra stage, cert-manager (sync wave 1). cert-manager solves ACME DNS-01
challenges by writing `_acme-challenge.<name>` TXT records into the **`irha.cz` zone at
Cloudflare**. Without this token no certificate is ever issued and every `Certificate` sits
`Pending`.

Design and rationale: [`docs/superpowers/specs/2026-09-01-tls-certificates.md`](superpowers/specs/2026-09-01-tls-certificates.md).

### Create the token (Cloudflare dashboard — manual, outside this repo)

**One token per cluster.** Secrets do not cross clusters, and cert-manager runs once per
cluster. Separate tokens mean one can be revoked without taking down the other two, and the
Cloudflare audit log attributes every TXT write to a cluster.

My Profile → API Tokens → *Create Token* → **Create Custom Token**:

| Field | Value |
|---|---|
| Name | `cert-manager-<cluster>` |
| Permissions | `Zone` · `DNS` · **Edit** |
| Permissions | `Zone` · `Zone` · **Read** |
| Zone Resources | Include · Specific zone · **`irha.cz`** |
| TTL / IP filtering | leave unset |

Nothing else. `Zone → Zone → Read` is what lets cert-manager find the zone ID for a name;
`Zone → DNS → Edit` is what lets it create and delete the challenge TXT. Account-level
permissions are not needed and must not be granted.

The token is shown **once**. Copy it straight into OpenBao.

### Store

```bash
bao kv put secret/<cluster>/cert-manager api-token=<cloudflare-token>
```

### Verify

```bash
# Key present, value not printed:
bao kv get -format=json secret/<cluster>/cert-manager | jq -r '.data.data | keys[]'

# Token is live and scoped to irha.cz (both must return "success": true):
T=$(bao kv get -field=api-token secret/<cluster>/cert-manager)
curl -s -H "Authorization: Bearer $T" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq '{success, status: .result.status}'
curl -s -H "Authorization: Bearer $T" \
  "https://api.cloudflare.com/client/v4/zones?name=irha.cz" | jq '{success, zone: .result[0].name}'
```

`Zone → DNS → Edit` cannot be proven by a read. First real proof is the staging `Certificate`
in stage 2 of the TLS spec: the TXT record appears in the Cloudflare dashboard during issuance
and disappears after.

No ESO policy change is needed: the path sits under `secret/data/<cluster>/*`, which every
cluster's `<cluster>-external-secrets` policy already grants ([iac.md](iac.md) step 3.d), and
server3's `read-secrets` covers `secret/data/*`.

**Status 2026-09-02:** seeded and verified for server1, server2 and server3 — three distinct
active tokens, each resolving the `irha.cz` zone.

---

## \<cluster\>/external-dns

**Required before:** gateway stage (`RootGateway.yaml` applied / cluster added to ExternalDNS ApplicationSet)

ExternalDNS pulls `unifi-credentials` via an `ExternalSecret` on first sync. If the secret is missing, ExternalDNS fails to start.

```bash
bao kv put secret/<cluster>/external-dns api-key=<unifi-api-key>

# Verify
bao kv get secret/<cluster>/external-dns
```

---

## \<cluster\>/influxdb2

**Required before:** iot stage (`RootIoT.yaml` applied / cluster added to InfluxDB2 ApplicationSet)

The Helm chart references `adminUser.existingSecret: influxdb2`. ESO syncs this secret from OpenBao before the pod starts. If the OpenBao path is empty, ESO sync fails and the pod never gets its secret — it will crashloop.

```bash
# admin-password: strong password (20+ chars). Used for UI login.
# admin-token:    operator API token. Any 20+ char string — InfluxDB2 accepts arbitrary values.
#   Generate:     openssl rand -base64 24 | tr -d '=+/'
bao kv put secret/<cluster>/influxdb2 \
  admin-password=<password> \
  admin-token=<token>

# Verify
bao kv get secret/<cluster>/influxdb2
```

See [provisioning.md](provisioning.md) for per-app scoped token provisioning after InfluxDB2 is running.

---

## \<cluster\>/emqx

**Required before:** iot stage (`RootIoT.yaml` applied / cluster added to EMQX ApplicationSet)

EMQX references `envFromSecret: emqx-credentials`. ESO syncs this secret from OpenBao before the pod starts. If the OpenBao path is empty, ESO sync fails and the pod never gets its credentials — it will crashloop.

```bash
# dashboard-username: EMQX dashboard admin username (e.g. admin).
# dashboard-password: strong password (20+ chars).
bao kv put secret/<cluster>/emqx \
  dashboard-username=<username> \
  dashboard-password=<password>

# Verify
bao kv get secret/<cluster>/emqx
```

See [provisioning.md](provisioning.md) for per-app MQTT user provisioning via the EMQX management API.

---

## \<cluster\>/mongodb

**Required before:** databases stage (`RootDatabases.yaml` applied / cluster added to MongoDB ApplicationSet)

The Bitnami MongoDB chart references `auth.existingSecret: mongodb`. ESO syncs this secret from OpenBao before the pod starts. If the OpenBao path is empty, ESO sync fails and the pod never gets its credentials — it will crashloop.

```bash
# root-password: strong password (20+ chars). Used for the MongoDB root user.
bao kv put secret/<cluster>/mongodb \
  root-password=<password>

# Verify
bao kv get secret/<cluster>/mongodb
```

See [provisioning.md](provisioning.md) for per-app scoped user provisioning via the MongoDB management API.

---

## otel-gateway/auth-token

**Required before:** observability stage on **any** cluster (k8s-monitoring on server1/server2 reads it via ESO).

Shared OTLP bearer token. server1/server2 k8s-monitoring sends it as `Authorization: Bearer` on outbound OTLP to `otel.server3.homelab.irha.cz:4317`. Single value — must be identical across clusters, so the path is intentionally outside the `secret/<cluster>/…` tree.

> **Note:** server3's `alloy-receiver` does **not** validate this token — the k8s-monitoring chart has no server-side OTLP auth. The endpoint is protected by private-network isolation only. See [observability.md](observability.md).

```bash
bao kv put secret/otel-gateway/auth-token token=$(openssl rand -base64 32 | tr -d '=+/')

# Verify
bao kv get secret/otel-gateway/auth-token
```

server3 ESO reads this via the `secret/data/*` wildcard in its `read-secrets` policy. server2 (and any additional cluster) ESO needs an explicit read grant — the `<cluster>-external-secrets` policy in [iac.md](iac.md) step 3.d grants `secret/data/otel-gateway/*` in addition to `secret/data/<cluster>/*`.

---

## \<cluster\>/influxdb2-grafana

**Provisioned at runtime** by the InfluxDB2 PostSync provisioner Job on that cluster
(`influxdb2-provision-loxone`). No manual seeding required.

The Job creates a read-only InfluxDB token scoped to the `loxone` and `loxone_downsample`
buckets and writes it here. **server3's** ESO — which reads `secret/data/*` — syncs it into the
`monitoring/<cluster>-influxdb2-grafana` Secret, and Grafana mounts it at
`/etc/secrets/<cluster>-influxdb2-grafana/token` for that cluster's InfluxDB datasource.

**The path is the writing cluster's own tree, and it has to be.** Each provisioner token is
scoped to `secret/data/<its own cluster>/*` — see the `<cluster>-provisioner` policy in
[iac.md](iac.md) step 3.e — so a Job simply cannot write anywhere else.

> **Fixed 2026-09-03.** This used to live at `secret/server3/<cluster>-influxdb2-grafana`, which
> no provisioner token has ever had permission to write. The value seeded at bootstrap on
> 2026-05-04 stayed valid — InfluxDB tokens do not expire — so Grafana kept working while every
> run of the Job failed on a 403 that nothing surfaced, because nothing alerts on a failed
> PostSync hook. Both paths were copied to the new location before the switch; the old
> `secret/server3/server{1,2}-influxdb2-grafana` entries are now unused and can be deleted.

To rotate: delete the path in OpenBao, delete the old InfluxDB2 authorization, then sync the
InfluxDB2 Application on that cluster. The token step is create-once — it skips when the path
already holds a value, so the delete is what actually triggers a new one.

```bash
# Verify (after InfluxDB2 PostSync runs)
bao kv get secret/<cluster>/influxdb2-grafana
```

---

## Verify all secrets for a cluster before deploying

```bash
bao kv list secret/<cluster>
bao kv list secret/otel-gateway   # once, not per cluster
```

---

## Picking up a rotated secret

A running pod never sees a changed Secret: env vars are frozen at container start, and the Jinja2 init container renders its config file once. [Stakater Reloader](https://github.com/stakater/Reloader) closes that gap — it watches ConfigMaps/Secrets and rolls the workloads that reference them.

**Opt-in.** Only workloads carrying `reloader.stakater.com/auto: "true"` on their *workload* metadata are restarted:

| Workload | Where the annotation lives |
| --- | --- |
| miot-bridge-api · qr-manager-api · qr-manager-ui · interactive-map-feeder-api | `gitops/helm-values/apps/<app>/base.yaml` → `annotations` |
| homelab-dashboard-ui | `gitops/helm-values/server3/homelab-dashboard-ui.yaml` → `annotations` |
| grafana | `gitops/helm-values/grafana.yaml` → `annotations` |
| external-dns | `gitops/helm-values/external-dns.yaml` → `deploymentAnnotations` |

**Timing.** ExternalSecrets poll with `refreshInterval: 1h`, so a write to OpenBao takes up to an hour to reach the Secret; Reloader then reacts in seconds. To skip the wait:

```bash
kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite
```

**Telegraf — manual.** The chart has no Deployment-level annotations key, so Reloader cannot be opted in from values. After rotating `telegraf-influxdb2-credentials` or `telegraf-mqtt-credentials`:

```bash
kubectl rollout restart deploy/telegraf -n telegraf
```

**Deliberately not automated.** InfluxDB2, EMQX and MongoDB consume their credentials at init time only — the live credential lives in the datastore, not in the Secret. Restarting them applies nothing and can interrupt writes, so rotation there stays the two-sided manual procedure described per path above.
