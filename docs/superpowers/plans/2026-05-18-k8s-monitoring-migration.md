# Migrate OTel Collectors to grafana/k8s-monitoring

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Replace the `otel-gateway` (OTel Collector, all clusters) and `apps-otel-collector` (per-namespace OTel Collector forwarders, server1/server2) with a single `grafana/k8s-monitoring` Helm chart deployment per cluster. Gain free infrastructure observability (node metrics, pod metrics, k8s events, container logs) while preserving app OTLP telemetry and trace-log correlation.

**Architecture:** Each cluster runs one `k8s-monitoring` release in the `monitoring` namespace. Alloy instances deployed internally by the chart handle all telemetry roles. server3 (LGTM cluster) points destinations to local Loki/Tempo/Prometheus services. server1/server2 (IoT clusters) forward all signals via a single OTLP destination to `otel.server3.home:4317` with bearer token auth — same external endpoint, only the backing service changes (IngressRouteTCP re-targeted to `alloy-receiver`). Per-namespace app collectors are eliminated; apps push OTLP directly to `alloy-receiver.monitoring.svc.cluster.local`. The `environment` attribute is dropped — `k8s.namespace.name` (`production`/`sandbox`) carries the same information automatically.

**Tech Stack:** `grafana/k8s-monitoring` chart, Grafana Alloy (internal), ExternalSecrets (unchanged), OpenBao (unchanged), ArgoCD GitOps, Traefik IngressRouteTCP.

**Auth note:** Current bearer token validation runs server-side in the OTel `bearertokenauth` extension. `k8s-monitoring` does not expose server-side OTLP receiver auth natively. Mitigation: the `otel.server3.home` endpoint is on the private home network; network-level isolation is sufficient. If auth must be retained, put Traefik ForwardAuth in front of the alloy-receiver service — deferred to a follow-up.

**Related:** iot-miniservers `docs/superpowers/specs/2026-05-18-k8s-monitoring-alignment.md` covers the app SDK and exporter URL changes that must follow this migration.

---

## Signal flow after migration

```
server1 / server2
  alloy-metrics (DaemonSet)  ─┐
  alloy-logs    (DaemonSet)  ─┤── OTLP ──► otel.server3.home:4317 (bearer token)
  alloy-receiver (Deployment) ─┤           (same external endpoint as today)
  alloy-singleton             ─┘

server3
  alloy-receiver (Deployment) ◄── OTLP from server1/server2 + local apps
    ├── metrics ──► prometheus.monitoring.svc:80/api/v1/write
    ├── logs    ──► loki.monitoring.svc:3100/otlp
    └── traces  ──► tempo.monitoring.svc:4317
  alloy-metrics  ─► same destinations (local)
  alloy-logs     ─► same destinations (local)
  alloy-singleton─► same destinations (local)
```

---

## Steps

### 1. Add k8s-monitoring Helm chart values — server3

- [x] Create `gitops/helm-values/server3/k8s-monitoring.yaml`:

```yaml
cluster:
  name: server3

destinations:
  prometheus:
    type: prometheus
    url: http://prometheus.monitoring.svc.cluster.local:80/api/v1/write
  loki:
    type: loki
    url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
  tempo:
    type: otlp
    url: http://tempo.monitoring.svc.cluster.local:4317
    protocol: grpc
    tls:
      insecure: true
    metrics: { enabled: false }
    logs: { enabled: false }
    traces: { enabled: true }

clusterMetrics:
  enabled: true
hostMetrics:
  enabled: true
podLogs:
  enabled: true
clusterEvents:
  enabled: true

applicationObservability:
  enabled: true
  receivers:
    otlp:
      grpc:
        enabled: true
      http:
        enabled: true
```

### 2. Add k8s-monitoring Helm chart values — server1/server2 (shared)

- [x] Create `gitops/helm-values/k8s-monitoring.yaml` (shared base for IoT clusters):

```yaml
# Shared base for server1/server2 — all signals forwarded to server3 via single OTLP destination.
clusterMetrics:
  enabled: true
hostMetrics:
  enabled: true
podLogs:
  enabled: true
clusterEvents:
  enabled: true

applicationObservability:
  enabled: true
  receivers:
    otlp:
      grpc:
        enabled: true
      http:
        enabled: true
```

### 3. Add k8s-monitoring Helm chart values — server1

- [x] Create `gitops/helm-values/server1/k8s-monitoring.yaml`:

```yaml
cluster:
  name: server1

destinations:
  server3:
    type: otlp
    url: http://otel.server3.home:4317
    protocol: grpc
    tls:
      insecure: true
    metrics: { enabled: true }
    logs: { enabled: true }
    traces: { enabled: true }
    auth:
      type: bearerToken
      bearerTokenFrom: env("OTEL_AUTH_TOKEN")
    secret:
      create: false
      name: otel-auth-token
```

### 4. Add k8s-monitoring Helm chart values — server2

- [x] Create `gitops/helm-values/server2/k8s-monitoring.yaml` (same as server1, different cluster name):

```yaml
cluster:
  name: server2

destinations:
  server3:
    type: otlp
    url: http://otel.server3.home:4317
    protocol: grpc
    tls:
      insecure: true
    metrics: { enabled: true }
    logs: { enabled: true }
    traces: { enabled: true }
    auth:
      type: bearerToken
      bearerTokenFrom: env("OTEL_AUTH_TOKEN")
    secret:
      create: false
      name: otel-auth-token
```

### 5. Create ArgoCD ApplicationSet for k8s-monitoring

- [x] Create `gitops/argocd-manifests/apps/observability/K8sMonitoring.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: k8s-monitoring
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - cluster: server1
            clusterServer: https://192.168.1.200:6443
          - cluster: server2
            clusterServer: https://192.168.1.201:6443
          - cluster: server3
            clusterServer: https://kubernetes.default.svc
  template:
    metadata:
      name: k8s-monitoring-{{cluster}}
    spec:
      project: default
      sources:
        - repoURL: https://grafana.github.io/helm-charts
          chart: k8s-monitoring
          targetRevision: 2.x.x   # pin to latest stable 2.x
          helm:
            releaseName: k8s-monitoring
            valueFiles:
              - $values/gitops/helm-values/k8s-monitoring.yaml
              - $values/gitops/helm-values/{{cluster}}/k8s-monitoring.yaml
        - repoURL: https://github.com/radoslavirha/homelab
          targetRevision: HEAD
          ref: values
      destination:
        server: '{{clusterServer}}'
        namespace: monitoring
      syncPolicy:
        managedNamespaceMetadata:
          labels:
            pod-security.kubernetes.io/enforce: privileged
        syncOptions:
          - CreateNamespace=true
        automated:
          selfHeal: true
          prune: true
```

> Note: server3 does not use the shared base; its values are self-contained. Override the `valueFiles` in the server3 element using a `templatePatch` or split into two generators if needed.

### 6. Update IngressRouteTCP on server3

- [x] Edit `gitops/k8s-manifests/server3/otel-gateway/IngressRouteTCP.otel-grpc.yaml`:
  - Change backend service from `otel-gateway-opentelemetry-collector` → `k8s-monitoring-alloy-receiver` (verify exact service name from chart output)
  - Port stays `4317`

### 7. Update HTTPRoute on server3 (if used for HTTP OTLP)

- [x] Edit `gitops/k8s-manifests/server3/otel-gateway/HTTPRoute.otel.yaml`:
  - Change backend service to `k8s-monitoring-alloy-receiver`
  - Port `4318`

### 8. Update app OTLP exporter URLs — 6 helm values files (18 references)

Replace `http://otel-collector-opentelemetry-collector:4318` → `http://k8s-monitoring-alloy-receiver.monitoring.svc.cluster.local:4318` in:

- [x] `gitops/helm-values/apps/miot-bridge-api/production.yaml`
- [x] `gitops/helm-values/apps/miot-bridge-api/sandbox.yaml`
- [x] `gitops/helm-values/apps/qr-manager-api/production.yaml`
- [x] `gitops/helm-values/apps/qr-manager-api/sandbox.yaml`
- [x] `gitops/helm-values/apps/interactive-map-feeder-api/production.yaml`
- [x] `gitops/helm-values/apps/interactive-map-feeder-api/sandbox.yaml`

> Verify `k8s-monitoring-alloy-receiver` is the actual service name by checking `helm template` output for the chart. Alternatively set `fullnameOverride` in the chart values to keep a stable name.

### 9. Remove OTelGateway ApplicationSet and values

- [x] Delete `gitops/argocd-manifests/apps/observability/OTelGateway.yaml`
- [x] Delete `gitops/helm-values/otel-gateway.yaml`
- [x] Delete `gitops/helm-values/server1/otel-gateway.yaml`
- [x] Delete `gitops/helm-values/server2/otel-gateway.yaml`
- [x] Delete `gitops/helm-values/server3/otel-gateway.yaml`

### 10. Remove AppsOTelCollector ApplicationSet and values

- [x] Delete `gitops/argocd-manifests/apps/apps/AppsOTelCollector.yaml`
- [x] Delete `gitops/helm-values/apps/otel-collector/base.yaml`
- [x] Delete `gitops/helm-values/apps/otel-collector/production.yaml`
- [x] Delete `gitops/helm-values/apps/otel-collector/sandbox.yaml`
- [x] Delete directory `gitops/helm-values/apps/otel-collector/`

### 11. Keep ExternalSecrets for otel-auth-token unchanged

- [x] Verify `gitops/k8s-manifests/server1/otel-gateway/ExternalSecret.otel-auth-token.yaml` and `server2` equivalent still sync the secret — no changes needed (secret name `otel-auth-token` unchanged, referenced by k8s-monitoring values above)
- [x] Rename/move files from `otel-gateway/` subfolder to a neutral location e.g. `gitops/k8s-manifests/server1/otel-auth/` to avoid confusion after otel-gateway is gone

### 12. Update documentation

- [x] Update `docs/architecture.md`: replace OTel Collector rows with k8s-monitoring; document new Alloy internal instance roles; update signal flow diagram
- [x] Update `docs/observability.md` (if exists): reflect new chart, new exporter URLs, drop per-namespace collector section
- [x] Update `gitops/README.md` references to otel-gateway if any

---

## Future: Beyla auto-instrumentation (optional Phase 2)

`k8s-monitoring` ships `autoInstrumentation.beyla` — eBPF-based zero-SDK instrumentation. Once k8s-monitoring is stable, enable Beyla to get RED metrics (Rate/Error/Duration) and basic traces for pods WITHOUT the OTel SDK (MongoDB, EMQX, Traefik). Label pods with `instrument: beyla` to opt in. Does not replace SDK-based instrumentation — complements it. Track as a separate superpowers plan.

---

## Implementation notes (2026-08-05) — deviations from the plan as written

The plan was drafted against chart v2. It was implemented against **4.3.2**, whose values schema differs substantially. Deviations:

| Plan said | Implemented as | Why |
|-----------|----------------|-----|
| `targetRevision: 2.x.x` | `4.3.2` | Nothing was ever deployed, so there was no migration cost to paying the v3/v4 breaking changes up front. |
| `destinations:` as a map of named objects (v2 wanted a list) | map keyed by name | v4.0.0 "Convert destinations into a map". |
| `alloy-metrics: {enabled: true}` etc. | explicit `collectors:` map + per-feature `collector:` assignment | v4.0.0 "Introduce `collectors` as map, and remove named Alloy instances". Collector names were kept identical, so all Service names and OTLP URLs are unchanged. |
| `podLogs.enabled: true` | `podLogsViaLoki` | v4.0.0 split Loki and OpenTelemetry log gathering. `podLogsViaOpenTelemetry` needs `otelcol.receiver.filelog` (public-preview) and would require lowering `stabilityLevel`. |
| — | `telemetryServices.kube-state-metrics.deploy` + `node-exporter.deploy` | v4 extracted these into a subchart with `deploy: false` defaults; `clusterMetrics`/`hostMetrics` need them. |
| `auth.bearerTokenFrom: env(...)` **plus** `secret.create: false` / `secret.name` | `auth.bearerTokenFrom` only, with `collectorCommon.alloy.envFrom` injecting the secret | Setting `secret.create: false` puts the destination in "external secret" mode, which emits `remote.kubernetes.secret` lookups for `tenantId`/`ca`/`cert`/`key` — absent from `otel-auth-token`, so Alloy would fail to load its config. |
| server3 values "self-contained", ApplicationSet overrides `valueFiles` per cluster | all clusters get shared base + cluster file | The `templatePatch` key in a list-generator element is not an ApplicationSet field — it would have been a dead parameter. The shared base carries no `destinations`, so a uniform two-file merge is correct. |
| `otel-gateway/` → `otel-auth/` manifest folder | `k8s-manifests/<cluster>/k8s-monitoring/` | The folder also holds the HTTPRoute and IngressRouteTCP, so "otel-auth" was a misnomer. |
| Keep the server3 `otel-auth-token` ExternalSecret | deleted | server3 only receives; it validates nothing and sends to local LGTM services without auth. |
| Step 11's bearer token "unchanged" | still synced on server1/server2, but **not validated** | `k8s-monitoring` has no server-side OTLP auth. Documented in `docs/observability.md`; Traefik ForwardAuth remains the follow-up.
| Four separate collectors (chart default) | **one** collapsed collector named `alloy-receiver` | Every cluster is single-node, so the reasons for splitting (DaemonSet locality, scrape sharding, singleton event dedup, independent receiver scaling) do not apply. Cuts 7 pods/cluster to 4 with no loss of telemetry. Must be split back before any cluster goes multi-node — replacement block is in the values file header and `docs/observability.md`. |
| App OTLP logs enabled | `otel.logs.enabled: false` in all 6 app values files | Winston already writes to stdout, which `podLogsViaLoki` now collects — pushing over OTLP too would double every line. stdout also survives OOMKills, startup failures, and Alloy outages. Trace↔log correlation is deferred; it needs a JSON parsing stage matched to the apps' actual stdout format. |
