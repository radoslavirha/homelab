# Observability Depth — Per-Service Instrumentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend observability coverage beyond the custom Node.js apps. Each deployed service should emit the deepest telemetry it is capable of — pod logs (free via podLogs), Prometheus metrics (native endpoints or exporters), and traces (native OTLP where available) — routed through the k8s-monitoring stack to Prometheus/Loki/Tempo on server3.

**Status (2026-08-05):** only Step 1 (Traefik) is done. Steps 2–11 are untouched and remain the next unit of work.

**Also deferred from the k8s-monitoring migration** (see `docs/observability.md` → "Open items"):

- [x] **Route logs to Loki's native OTLP endpoint** (done 2026-08-11). server3's `loki` destination changed from `type: loki` to `type: otlp` → `:3100/otlp`. `type: loki` renders the deprecated `otelcol.exporter.loki`, which always JSON-envelopes the line and never emits structured metadata. See `docs/observability.md` → "Why logs use `type: otlp`".
- [x] **Reverted: SDK log export.** Briefly enabled 2026-08-11, then turned back off the same day. It was enabled because the scraped copy looked much worse — but that was caused by `otelcol.exporter.loki`, not by scraping. Once the destination was fixed the comparison no longer held, and SDK export cannot cover pre-init boot output, OOMKills or the unflushed batch buffer. `otel.logs.enabled: false` in all six config templates.
- [x] **Reverted: scrape opt-out.** Same story — `logs.grafana.com/pods.enabled: "false"` was added and then removed. Recorded because the trap is easy to hit again: the annotation must go in `podAnnotations`, *not* `annotations`, which lands on the workload metadata where Alloy never looks and fails silently.
- [x] **`resource.opentelemetry.io/service.name|service.version` pod annotations** (done 2026-08-11). Injected by the `iot-applications` chart in `deployment.yaml`/`rollout.yaml` rather than per app, with `service.version` templated from `image.tag` so it cannot drift and picks up the per-environment override. `service.name` was already correct via the `app.kubernetes.io/name` fallback; declaring it removes the dependence on that coincidence. `service.namespace` not set — the chart already resolves it from the pod namespace.
- [x] **`podLogsViaLoki.extraLogProcessingStages`** (done 2026-08-11) for `level`/`trace_id`/`span_id`. Restores the trace↔log correlation that SDK export gave for free. Both `stage.json` and `stage.structured_metadata` must live in `extraLogProcessingStages` — the chart renders its own `structuredMetadata:` key *before* that block, so splitting them silently maps nothing.

**Prerequisite:** k8s-monitoring migration complete (see `docs/superpowers/plans/2026-05-18-k8s-monitoring-migration.md`). Alloy-receiver endpoint and podLogs are live.

---

## Service audit

| Service | Pod logs | Metrics | Traces | Approach |
|---------|:--------:|:-------:|:------:|----------|
| **Traefik** | Auto ✓ (podLogs) | OTLP → alloy-receiver ✓ already | OTLP → alloy-receiver ✓ already | Update endpoint URL only; OTLP logs removed (podLogs handles) |
| **MongoDB** | Auto ✓ | `metrics.enabled: true` in Bitnami chart (mongodb-exporter sidecar on `:9216`) | ✗ custom wire protocol | 1-line helm change |
| **EMQX** | Auto ✓ | Pull mode at `:18083/api/v5/prometheus/stats` (no auth by default) | ✗ OTel is Enterprise-edition only | Custom PodMonitor manifest |
| **InfluxDB2** | Auto ✓ | Built-in at `:80/metrics` (always on) | ✗ not available | Custom PodMonitor manifest |
| **Grafana** | Auto ✓ | Built-in at `:3000/metrics` (always on) | `[tracing.opentelemetry.otlp]` in `grafana.ini` | k8s-monitoring integration + `grafana.ini` tracing |
| **Loki** | Auto ✓ | Built-in at `:3100/metrics` | ✗ not available | k8s-monitoring integration |
| **Tempo** | Auto ✓ | Built-in at `:3200/metrics` | ✗ not available | k8s-monitoring integration |
| **Prometheus** | Auto ✓ | Self-scrape at `/-/metrics` | ✗ not applicable | k8s-monitoring integration |
| **ArgoCD** | Auto ✓ | Per-component metrics; chart-native ServiceMonitor toggle | ✗ not available in OSS | `metrics.enabled + serviceMonitor.enabled` in argocd.yaml |
| **Longhorn** | Auto ✓ | Built-in at `:9500/metrics` (longhorn-manager); chart-native ServiceMonitor toggle | ✗ not available | `monitoring.serviceMonitor.enabled: true` in IaC values |
| **qr-manager-ui (nginx)** | Auto ✓ (nginx access logs collected by podLogs) | — | — | No action; access logs in Loki covers it |
| **Custom APIs** | OTLP → podLogs ✓ | OTLP ✓ | OTLP SDK ✓ | URL update (covered in alignment spec) |
| **Telegraf** | Auto ✓ | — | — | No action; sends to InfluxDB2, not OTLP |

**Why EMQX OTel is not used:** EMQX native OpenTelemetry (`emqx_otel` application) is **Enterprise Edition only** from v5.8.3. The homelab runs EMQX OSS 5.8.9. Pull-mode Prometheus scraping is the correct approach for OSS.

**Why Beyla is deferred:** Beyla is useful for HTTP/gRPC processes with no native OTel SDK. All services here either already have native metrics endpoints (preferred) or use a protocol Beyla cannot decode (MQTT for EMQX, MongoDB wire protocol). Beyla deferred to Phase 3 for InfluxDB2 HTTP write traces.

---

## Steps

### 1. Traefik — update OTLP endpoint URL

Traefik already emits traces, metrics, and logs via OTLP gRPC (`gitops/helm-values/traefik.yaml` already has `tracing.otlp`, `metrics.otlp`, and `logs.general.otlp` configured). After k8s-monitoring migration the three endpoint references must point to `alloy-receiver`.

- [x] In `gitops/helm-values/traefik.yaml`, remove `logs.general.otlp`, `logs.access.otlp`, and `experimental.otlpLogs: true` — pod logs collected by alloy podLogs instead (already done)
- [x] In `gitops/helm-values/traefik.yaml`, replace the two remaining endpoint references (`tracing.otlp.grpc.endpoint`, `metrics.otlp.grpc.endpoint`) from `otel-gateway-opentelemetry-collector.monitoring.svc.cluster.local:4317` to `k8s-monitoring-alloy-receiver.monitoring.svc.cluster.local:4317`

> This step is also listed in the k8s-monitoring migration plan — only do it once.

---

### 2. MongoDB — enable bundled mongodb-exporter sidecar

Bitnami mongodb chart v18 bundles a `mongodb-exporter` sidecar. Enabling it starts the exporter on `:9216/metrics`. The chart also creates a `ServiceMonitor` when `metrics.serviceMonitor.enabled: true`, which alloy-metrics picks up automatically.

- [ ] In `gitops/helm-values/mongodb.yaml`, add:

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    namespace: monitoring   # must match the namespace where Prometheus/alloy is configured to watch
    interval: 30s
```

- [ ] After ArgoCD sync confirm the metrics Service and ServiceMonitor exist: `kubectl get servicemonitor -n databases` (or whichever namespace MongoDB runs in)
- [ ] Confirm metrics in Prometheus: `mongodb_up`, `mongodb_connections_current`, `mongodb_opcounters_total`

---

### 3. EMQX — scrape built-in Prometheus pull endpoint

EMQX OSS exposes three Prometheus pull endpoints on the management port `:18083`:

| Path | Content |
|------|---------|
| `/api/v5/prometheus/stats` | connections, messages, sessions, rule engine |
| `/api/v5/prometheus/auth` | auth/ACL counters |
| `/api/v5/prometheus/data_integration` | connectors, actions, bridges |

By default these require **no authentication** (auth can be enabled from the EMQX dashboard under Monitoring → Integration → Prometheus).

- [ ] Verify auth is disabled (or note credentials if enabled): open EMQX dashboard → Management → Monitoring → Integration → Prometheus → Enable Basic Auth toggle — confirm off

- [ ] Create `gitops/k8s-manifests/server2/emqx/PodMonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: emqx
  namespace: monitoring   # must match alloy-metrics watchNamespaces or be cluster-wide
spec:
  namespaceSelector:
    matchNames:
      - iot
  selector:
    matchLabels:
      app.kubernetes.io/name: emqx
  podMetricsEndpoints:
    - port: management   # port name in EMQX pod spec (18083)
      path: /api/v5/prometheus/stats
      interval: 30s
    - port: management
      path: /api/v5/prometheus/auth
      interval: 30s
    - port: management
      path: /api/v5/prometheus/data_integration
      interval: 30s
```

> The exact port name must match what the EMQX chart exposes. Verify with: `kubectl get pod -n iot -l app.kubernetes.io/name=emqx -o jsonpath='{.items[0].spec.containers[0].ports}'`

- [ ] Confirm metrics in Prometheus: `emqx_connections_count`, `emqx_messages_sent_total`, `emqx_messages_received_total`, `emqx_rules_matched_total`

---

### 4. InfluxDB2 — scrape built-in metrics endpoint

InfluxDB2 exposes Prometheus-format metrics at `/metrics` on the same HTTP port (`:80` per `service.port` in `influxdb2.yaml`). No configuration change needed on the InfluxDB2 side.

- [ ] Create `gitops/k8s-manifests/server2/influxdb2/PodMonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: influxdb2
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
      - iot
  selector:
    matchLabels:
      app.kubernetes.io/name: influxdb2
  podMetricsEndpoints:
    - port: http   # port name in InfluxDB2 pod spec (:8086 container port, exposed as :80 via service)
      path: /metrics
      interval: 30s
```

> Verify the container port name: `kubectl get pod -n iot -l app.kubernetes.io/name=influxdb2 -o jsonpath='{.items[0].spec.containers[0].ports}'`

- [ ] Confirm metrics in Prometheus: `influxdb_write_requests_total`, `influxdb_query_requests_total`, `go_goroutines`

---

### 5. Grafana — enable OTLP traces + k8s-monitoring integration

Grafana emits traces via `[tracing.opentelemetry.otlp]` in `grafana.ini`. It also exposes Prometheus metrics at `:3000/metrics` (always-on). The k8s-monitoring `grafana` integration creates a ServiceMonitor automatically.

#### 5a. Enable OTLP tracing

- [ ] In `gitops/helm-values/grafana.yaml`, add:

```yaml
grafana.ini:
  tracing.opentelemetry.otlp:
    address: k8s-monitoring-alloy-receiver.monitoring.svc.cluster.local:4317
    propagation: w3c
    insecure: "true"
```

> Note: in the Grafana Helm chart, `grafana.ini` sections map directly. The key is the INI section name in dot notation. `insecure` must be a quoted string `"true"` in YAML to avoid type mismatch.

#### 5b. Add k8s-monitoring `grafana` integration

- [ ] In `gitops/helm-values/server3/k8s-monitoring.yaml`, add to the `integrations` block:

```yaml
integrations:
  grafana:
    instances:
      - name: grafana
        namespaces: [monitoring]
        labelSelectors:
          app.kubernetes.io/name: grafana
```

---

### 6. Loki and Tempo — k8s-monitoring integrations

Both expose Prometheus metrics at `:3100/metrics` (Loki) and `:3200/metrics` (Tempo). k8s-monitoring has first-class integrations for both.

> Note: `monitoring.selfMonitoring.enabled: false` is currently set in `loki.yaml` — this disables the Loki-internal Grafana Agent scraping, which is correct since k8s-monitoring replaces it.

- [ ] In `gitops/helm-values/server3/k8s-monitoring.yaml`, add to the `integrations` block:

```yaml
  loki:
    instances:
      - name: loki
        namespaces: [monitoring]
        labelSelectors:
          app.kubernetes.io/name: loki

  tempo:
    instances:
      - name: tempo
        namespaces: [monitoring]
        labelSelectors:
          app.kubernetes.io/name: tempo
```

---

### 7. Prometheus — self-scrape via k8s-monitoring

Prometheus exposes `/metrics` on `:9090` (internal container port) / `:80` (Service port via `fullnameOverride: prometheus`).

- [ ] In `gitops/helm-values/server3/k8s-monitoring.yaml`, add to the `integrations` block (k8s-monitoring does not have a first-class Prometheus integration, but `alloy` integration covers Alloy self-monitoring; for Prometheus use a raw ServiceMonitor):

  Add ServiceMonitor separately:

- [ ] Create `gitops/k8s-manifests/server3/prometheus/ServiceMonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: prometheus
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
      app.kubernetes.io/component: server
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

- [ ] Confirm self-scrape metrics appear: `prometheus_tsdb_head_samples_appended_total`, `prometheus_http_requests_total`

---

### 8. ArgoCD — enable per-component ServiceMonitors

ArgoCD Helm chart supports `metrics.enabled` and `metrics.serviceMonitor.enabled` per component. ArgoCD runs in the `argocd` namespace on server3.

- [ ] In `gitops/helm-values/server3/argocd.yaml`, add:

```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels: {}   # add any labels required by alloy-metrics serviceMonitorNamespaceSelector

server:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

repoServer:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

applicationSet:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
```

- [ ] Confirm metrics in Prometheus: `argocd_app_info`, `argocd_app_sync_total`, `argocd_git_request_duration_seconds`, `argocd_app_k8s_request_total`

---

### 9. Longhorn — enable ServiceMonitor

Longhorn exposes Prometheus metrics at `:9500/metrics` on each `longhorn-manager` pod. The Longhorn Helm chart ships with a toggle.

- [ ] In `iac/clusters/helm-values/longhorn.yaml` (shared), add:

```yaml
monitoring:
  serviceMonitor:
    enabled: true
```

- [ ] Run `terraform apply -auto-approve` for each cluster's platform stage:
  - `cd iac/clusters/server2/platform && terraform apply -auto-approve`
  - `cd iac/clusters/server3/platform && terraform apply -auto-approve`
- [ ] Confirm metrics: `longhorn_volume_state`, `longhorn_volume_capacity_bytes`, `longhorn_node_count_total`

---

### 10. k8s-monitoring — enable alloy integration (self-monitoring)

The `alloy` k8s-monitoring integration scrapes Alloy's own metrics (all four Alloy instances: metrics, logs, receiver, singleton).

- [ ] In `gitops/helm-values/server3/k8s-monitoring.yaml` (and shared base if applicable), add to `integrations`:

```yaml
  alloy:
    instances:
      - name: alloy-metrics
        namespaces: [monitoring]
        labelSelectors:
          app.kubernetes.io/name: alloy-metrics
      - name: alloy-logs
        namespaces: [monitoring]
        labelSelectors:
          app.kubernetes.io/name: alloy-logs
      - name: alloy-receiver
        namespaces: [monitoring]
        labelSelectors:
          app.kubernetes.io/name: alloy-receiver
```

---

### 11. Update documentation

- [ ] Update `docs/architecture.md`: for each row (MongoDB, EMQX, InfluxDB2, ArgoCD, Longhorn, Grafana, Loki, Tempo, Traefik) add or update notes indicating which signals are now emitted (Logs ✓ Auto / Metrics ✓ Prometheus / Traces ✓ OTLP)
- [ ] Update `docs/observability.md` if it exists: add a section listing signals per service and their destination (Loki for logs, Prometheus for metrics, Tempo for traces)

---

## Summary of file changes

| File | Change |
|------|--------|
| `gitops/helm-values/traefik.yaml` | Replace 3 OTLP endpoint URLs |
| `gitops/helm-values/mongodb.yaml` | Add `metrics.enabled: true`, `metrics.serviceMonitor.enabled: true` |
| `gitops/k8s-manifests/server2/emqx/PodMonitor.yaml` | New — scrape 3 EMQX Prometheus paths |
| `gitops/k8s-manifests/server2/influxdb2/PodMonitor.yaml` | New — scrape `/metrics` |
| `gitops/helm-values/grafana.yaml` | Add `grafana.ini.[tracing.opentelemetry.otlp]` |
| `gitops/helm-values/server3/k8s-monitoring.yaml` | Add integrations for grafana, loki, tempo, alloy |
| `gitops/k8s-manifests/server3/prometheus/ServiceMonitor.yaml` | New — Prometheus self-scrape |
| `gitops/helm-values/server3/argocd.yaml` | Add per-component `metrics.enabled + serviceMonitor.enabled` |
| `iac/clusters/helm-values/longhorn.yaml` | Add `monitoring.serviceMonitor.enabled: true` |
| `docs/architecture.md` | Update observability columns per-service |

---

## Future: Beyla eBPF (optional Phase 3)

Once k8s-monitoring is stable, enable `autoInstrumentation.beyla` for HTTP-serving pods that have no native OTel (InfluxDB2 HTTP write endpoint, nginx for qr-manager-ui). Add `instrument: beyla` label to target pods. Gives RED metrics (Rate/Error/Duration) and basic HTTP span traces without any app changes. Track as a separate plan.
