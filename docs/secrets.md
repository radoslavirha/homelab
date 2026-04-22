# Secrets Reference

All application secrets are stored in OpenBao (KV v2, mount `secret`) on the **server3** cluster and synced to all clusters via External Secrets Operator (ESO).

This document is the single source of truth for **what must exist in OpenBao before each deployment stage**.  
Every stage in `docs/iac.md` and `gitops/README.md` that requires secrets links here.

---

## Quick reference — all paths

| OpenBao path | Keys | Required before | Cluster |
|---|---|---|---|
| `secret/server3/argocd` | `adminPasswordHash` | ArgoCD install (`apps` stage) | server3 |
| `secret/<cluster>/external-dns` | `api-key` | gateway stage | any |
| `secret/server3/grafana` | `admin-user`, `admin-password` | observability stage | server3 |
| `secret/<cluster>/influxdb2` | `admin-password`, `admin-token` | iot stage | any |
| `secret/<cluster>/emqx` | `dashboard-username`, `dashboard-password` | iot stage | any |
| `secret/<cluster>/mongodb` | `root-password` | databases stage | any |
| `secret/otel-gateway/auth-token` | `token` | observability stage | server3, server2 |

`<cluster>` is the short cluster name: `server2`, `server3`, etc.

---

## How to open an OpenBao session

### When vault.server3.home is reachable (DNS + Traefik running)

```bash
export BAO_ADDR=http://vault.server3.home
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

## Verify all secrets for a cluster before deploying

```bash
bao kv list secret/<cluster>
```
