# Custom Apps GitOps Onboarding — Design Spec

**Date:** 2026-04-23  
**Status:** Approved — Phase 1 complete  
**Source repo:** `/Users/radoslavirha/dev/irha/home-server2` (reference for all values, versions, secrets)

---

## Goal

Onboard `miot-bridge-api-iot` and `interactive-map-feeder-api-iot` into the homelab GitOps pipeline with:
- `production` / `sandbox` namespace isolation (shared namespaces, all custom apps share them)
- Per-namespace OTEL telemetry enrichment (adds `environment` label)
- Clean separation from IoT infrastructure apps (EMQX, InfluxDB2, Telegraf)
- Helm chart hosted in this repo (no external publishing needed)

---

## Architecture

```
Custom apps stage (ArgoCD apps project):

RootApps.yaml (manual apply once)
  └── apps/apps/ (ApplicationSets)
        ├── AppsOTelCollector    → monitoring in production + sandbox ns
        ├── MiotBridgeApiIot     → production + sandbox ns
        └── InteractiveMapFeederApiIot → production + sandbox ns

Telemetry flow:
  app pod
    → apps-otel-collector (same namespace; adds environment=production|sandbox)
    → otel-gateway.monitoring.svc.cluster.local:4317  (in-cluster, no auth)
    → server3 central otel-gateway
    → Loki / Tempo / Prometheus
```

---

## Decisions

### 1. Namespace model: shared production + sandbox

All custom apps share `production` and `sandbox` namespaces (not per-app namespaces). Simple, easy to reason about. Per-app namespace isolation can be introduced later if needed.

### 2. Helm chart: path-based in this repo

Chart lives at `gitops/helm-charts/iot-applications/`. ArgoCD references it directly via `path:` — no registry, no publishing pipeline. Extractable to OCI/ghcr.io later: only `repoURL`/`chart` fields in ApplicationSets change.

**Important: values structure (from chart Readme):**

```
gitops/helm-values/apps/
  {app}/
    base.yaml           ← shared: image, resources, labels, services, ingress, templates.file/path
    production.yaml     ← env-specific: replicas, templates.content (Jinja2 config body)
    sandbox.yaml
  {app}/variables/
    production.yaml     ← VAR_* values injected into Jinja2 at runtime
    sandbox.yaml
```

Service naming pattern: `{component}-{partOf}-{app}-{serviceName}` (e.g. `api-iot-miot-bridge-http`)

### 3. ApplicationSet generator: matrix (clusters × environments)

```yaml
generators:
  - matrix:
      generators:
        - list:
            elements:
              - cluster: server2
                clusterServer: https://192.168.1.201:6443
        - list:
            elements:
              - env: production
              - env: sandbox
```

Produces: `miot-bridge-api-iot-server2-production`, `miot-bridge-api-iot-server2-sandbox`.
Adding server1 later = add one element to the cluster list.

### 4. Per-namespace OTEL collector

One OTEL collector deployment per (cluster, environment) namespace. Deployed via ApplicationSet with same matrix generator. Adds `environment=production|sandbox` resource attribute to all telemetry. Forwards in-cluster to `otel-gateway.monitoring.svc.cluster.local:4317` — insecure TLS, no bearer token needed (in-cluster).

Does **not** replace the existing `otel-gateway` in `monitoring` namespace — that remains the central fan-out to Loki/Tempo/Prometheus.

### 5. Secrets: ESO + OpenBao (not SealedSecrets)

The chart's Readme documents SealedSecrets — this is the old home-server2 pattern. We use External Secrets Operator + OpenBao, consistent with all other apps in this repo.

The chart templates consume secrets by K8s Secret name via `secretRefs` — they work with ESO-generated secrets transparently. Only the Readme is misleading; the chart itself is agnostic.

ExternalSecrets are namespace-scoped, wave `-1`. OpenBao KV paths: `server2/{app-name}/{env}`.

### 6. AppProject: apps (new, separate from iot)

New `apps` AppProject created in `roots/projects/apps.yaml` (integrates with the 2026-04-22 restructure plan at wave 0). ApplicationSets use `project: default` until the restructure plan is executed.

`RootApps.yaml` is applied manually once (same as other Root Applications). When the restructure plan runs, it moves into `roots/` with sync-wave `"3"` (same wave as RootIoT — depends on Traefik and ESO).

### 7. server1: out of scope

server1 is a future clone of server2. Add to matrix list generators when set up.

---

## Directory layout (new files)

```
gitops/
  helm-charts/
    iot-applications/                      ← DONE (Phase 1)
  argocd-manifests/
    RootApps.yaml                          ← Phase 2
    roots/projects/
      apps.yaml                            ← Phase 2 (AppProject for restructure plan)
    apps/apps/
      AppsOTelCollector.yaml               ← Phase 3
      MiotBridgeApiIot.yaml                ← Phase 4
      InteractiveMapFeederApiIot.yaml      ← Phase 4
  helm-values/
    apps/
      otel-collector/
        base.yaml                          ← Phase 3
        production.yaml                    ← Phase 3
        sandbox.yaml                       ← Phase 3
      miot-bridge-api-iot/
        base.yaml                          ← Phase 5
        production.yaml                    ← Phase 5
        sandbox.yaml                       ← Phase 5
        variables/
          production.yaml                  ← Phase 5 (VAR_* for Jinja2)
          sandbox.yaml                     ← Phase 5
      interactive-map-feeder-api-iot/
        base.yaml                          ← Phase 5
        production.yaml                    ← Phase 5
        sandbox.yaml                       ← Phase 5
        variables/
          production.yaml                  ← Phase 5
          sandbox.yaml                     ← Phase 5
    server2/apps/
      miot-bridge-api-iot/
        production.yaml                    ← Phase 5 (cluster override stub)
        sandbox.yaml                       ← Phase 5
      # interactive-map-feeder-api-iot: NO cluster overrides needed
    server2/
      traefik.yaml                         ← Phase 2 (add UDP entrypoints)
  k8s-manifests/server2/
    emqx/
      provisioner-miot-bridge-production.yaml  ← Phase 5 (PostSync Job: create EMQX MQTT user, write to OpenBao)
      provisioner-miot-bridge-sandbox.yaml     ← Phase 5
    mongodb/
      provisioner-miot-bridge-production.yaml  ← Phase 5 (PostSync Job: create MongoDB user/db, write to OpenBao)
      provisioner-miot-bridge-sandbox.yaml     ← Phase 5
    miot-bridge-api-iot/
      production/ExternalSecret.mqtt.yaml       ← Phase 5 (pulls from OpenBao written by provisioner)
      production/ExternalSecret.mongodb.yaml    ← Phase 5
      sandbox/ExternalSecret.mqtt.yaml          ← Phase 5
      sandbox/ExternalSecret.mongodb.yaml       ← Phase 5
    # interactive-map-feeder-api-iot: NO ExternalSecrets (no secretRefs)
docs/
  architecture.md                          ← Phase 6 (add rows for all new components)
```

---

## Architecture table rows to add (Phase 6)

| Component | Purpose | Clusters | Managed by | Artifact Hub | Local values | Upstream |
|-----------|---------|----------|------------|--------------|--------------|----------|
| iot-applications (chart) | Shared Helm chart for custom IoT apps | server2 | ArgoCD `apps` | — | [chart](../gitops/helm-charts/iot-applications/) | — |
| miot-bridge-api-iot | MIOT bridge API | server2 | ArgoCD `apps` | — | `apps/miot-bridge-api-iot/` · `server2/apps/miot-bridge-api-iot/` | — |
| interactive-map-feeder-api-iot | Interactive map feeder API | server2 | ArgoCD `apps` | — | `apps/interactive-map-feeder-api-iot/` · `server2/apps/interactive-map-feeder-api-iot/` | — |
| Apps OTel Collector | Per-namespace OTLP forwarder; adds `environment` label, forwards to otel-gateway in-cluster | server2 | ArgoCD `apps` | [opentelemetry-collector](https://artifacthub.io/packages/helm/opentelemetry-helm-charts/opentelemetry-collector) | `apps/otel-collector/` | [values.yaml](https://github.com/open-telemetry/opentelemetry-helm-charts/blob/main/charts/opentelemetry-collector/values.yaml) |

---

## Deployment sequence (first boot)

```bash
# 1. Apply RootApps once (after RootGateway and RootInfra are running)
kubectl apply -f gitops/argocd-manifests/RootApps.yaml

# 2. ArgoCD creates production + sandbox namespaces via CreateNamespace=true
# 3. OTEL collectors start in each namespace

# 4. EMQX and MongoDB provisioner Jobs run automatically as PostSync hooks on
#    their respective ApplicationSets (emqx, mongodb). They create MQTT users
#    and MongoDB users/databases, then write credentials to OpenBao.

# 5. ExternalSecrets in production/sandbox pull credentials from OpenBao (wave -1)
#    → miot-bridge pods start once secrets are available

# 6. interactive-map-feeder pods start immediately (no secrets needed)
```

---

## Open questions (for Phase 5)

~~- What Docker image repositories/tags do these apps publish to?~~
~~- What exact secret keys does each app need?~~
~~- Does `miot-bridge-api-iot` need UDP ingress?~~
~~- What `VAR_PUBLIC_DOMAIN` value should production vs sandbox use?~~
~~- Should sandbox use a different image tag than production?~~

All resolved from home-server2 — see concrete values below.

---

## Resolved Values (from home-server2)

### Image versions (pinned)

| App | Image | Production tag | Sandbox tag |
|-----|-------|---------------|-------------|
| miot-bridge-api-iot | `radoslavirha/miot-bridge` | `0.16.0` | `0.16.0` |
| interactive-map-feeder-api-iot | `radoslavirha/interactive-map-feeder` | `0.6.0` | `0.6.0` |

### Variables

| Variable | Production | Sandbox |
|----------|-----------|---------|
| `VAR_PROTOCOL` | `http` | `http` |
| `VAR_PUBLIC_DOMAIN` | `server2.home` | `server2.home` |
| `VAR_SUBDOMAIN` | _(not set)_ | `sandbox` |
| `VAR_MQTT_URL` | `mqtt://emqx-headless.iot.svc.cluster.local:1883` | same |
| `VAR_MONGODB_URL` | `mongodb://mongodb.mongodb.svc.cluster.local:27017` | same |

Note: In home-server2 EMQX was in `mqtt` namespace; in homelab it is in `iot` namespace — MQTT URL updated accordingly.

### URL patterns

- Production: `http://api.server2.home/iot/<pathName>`
- Sandbox: `http://sandbox.api.server2.home/iot/<pathName>`

### Secrets

**miot-bridge-api-iot** has two `secretRefs`:
- `miot-bridge-api-mqtt-credentials` → keys: `SECRET_MQTT_MIOT_BRIDGE_USERNAME`, `SECRET_MQTT_MIOT_BRIDGE_PASSWORD`
- `miot-bridge-api-mongodb-credentials` → keys: `SECRET_MONGODB_DATABASE`, `SECRET_MONGODB_USERNAME`, `SECRET_MONGODB_PASSWORD`

**interactive-map-feeder-api-iot** has **no `secretRefs`** → no ExternalSecrets needed.

Credentials are **auto-generated by provisioner PostSync Jobs** — same pattern as `emqx/provisioner-telegraf.yaml` and `influxdb2/provisioner-telegraf.yaml`. Never manually seeded.

**Provisioner approach:** Provisioner Jobs run in the `iot` namespace (where `openbao-provision-token` and `emqx-credentials` already exist). This avoids replicating admin credentials to `production`/`sandbox` namespaces.

- **EMQX provisioner** (`gitops/k8s-manifests/server2/emqx/`): PostSync Job per env — creates MQTT user `miot-bridge-{env}`, writes to OpenBao at `server2/miot-bridge-api-iot/{env}` (keys: `mqtt-username`, `mqtt-password`)
- **MongoDB provisioner** (`gitops/k8s-manifests/server2/mongodb/`): PostSync Job per env — creates database + user `miot-bridge-{env}`, writes to OpenBao at `server2/miot-bridge-api-iot/{env}` (keys: `mongodb-database`, `mongodb-username`, `mongodb-password`). Needs `mongodb-root-password` secret available in `mongodb` namespace (already exists via ExternalSecret).

ExternalSecrets in `production`/`sandbox` namespaces pull the provisioner-written paths from OpenBao (wave `-1`, same as other app ExternalSecrets).

OpenBao KV paths written by provisioners:
- `server2/miot-bridge-api-iot/production` → `mqtt-username`, `mqtt-password`, `mongodb-database`, `mongodb-username`, `mongodb-password`
- `server2/miot-bridge-api-iot/sandbox` → same keys

### UDP ingress (miot-bridge only)

Traefik needs two new UDP entrypoints added to `gitops/helm-values/server2/traefik.yaml`:
- `udp-miot-prod` → port `4000`, `expose.default: false`
- `udp-miot-sbx` → port `4001`, `expose.default: false`

This is a **prerequisite** for miot-bridge to work and must be done in Phase 2 (alongside RootApps scaffolding) so Traefik is updated before the app is deployed.

### OTel collector service name

Helm release name for the per-namespace collector must be `otel-collector` so the auto-generated service name is `otel-collector-opentelemetry-collector` — this matches the hardcoded endpoint in the app config templates:
```
http://otel-collector-opentelemetry-collector:4318/v1/metrics
```

### ArgoCD Application structure (home-server2 reference)

home-server2 uses singleton `Application` per (app, env). We use `ApplicationSet` with matrix generator — produces the same deployments but is cleaner. Value files passed per app:

**miot-bridge-api-iot:**
```
valueFiles:
  - $values/gitops/helm-values/apps/miot-bridge-api-iot/base.yaml
  - $values/gitops/helm-values/apps/miot-bridge-api-iot/{{env}}.yaml
  - $values/gitops/helm-values/apps/miot-bridge-api-iot/variables/{{env}}.yaml
  - $values/gitops/helm-values/server2/apps/miot-bridge-api-iot/{{env}}.yaml   ← cluster overrides
```

**interactive-map-feeder-api-iot:**
```
valueFiles:
  - $values/gitops/helm-values/apps/interactive-map-feeder-api-iot/base.yaml
  - $values/gitops/helm-values/apps/interactive-map-feeder-api-iot/{{env}}.yaml
  - $values/gitops/helm-values/apps/interactive-map-feeder-api-iot/variables/{{env}}.yaml
  # no cluster override file — no server2-specific values needed
```

k8s-manifests path (ExternalSecrets): `gitops/k8s-manifests/server2/<app>/<env>/`
