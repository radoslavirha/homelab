---
description: "Rules for Alloy (k8s-monitoring), Loki, Tempo, Prometheus and Grafana values and manifests"
applyTo: "gitops/helm-values/k8s-monitoring.yaml,gitops/helm-values/*/k8s-monitoring.yaml,gitops/helm-values/loki.yaml,gitops/helm-values/tempo.yaml,gitops/helm-values/prometheus.yaml,gitops/helm-values/*/prometheus.yaml,gitops/helm-values/grafana.yaml,gitops/helm-values/*/grafana.yaml,gitops/k8s-manifests/server3/grafana/**,gitops/k8s-manifests/*/k8s-monitoring/**"
---

# Observability

Full guide: `docs/observability.md`. The traps below have each cost hours.

## Logs path

- Alloy ships logs to Loki's **native OTLP endpoint** (`/otlp/v1/logs`). Index labels are therefore
  the OTel names — `k8s_cluster_name`, `k8s_namespace_name`, `k8s_pod_name`, `service_name`. Plain
  `cluster`, `namespace`, `pod` exist only as structured metadata; a selector on `{cluster="…"}`
  matches nothing and looks exactly like missing logs.
- server3's logs destination is `type: otlp`, **not** `type: loki`. `type: loki` renders the
  deprecated `otelcol.exporter.loki`, which JSON-envelopes every line and never emits structured
  metadata. It also needs `clusterLabels: []` plus guarded OTTL, or it relabels every cluster's logs as
  server3.
- `podLogsViaLoki.extraLogProcessingStages` lifts `level`/`trace_id`/`span_id` out of JSON lines into
  structured metadata. **Both** `stage.json` and `stage.structured_metadata` must live there — the
  chart renders its own `structuredMetadata:` key earlier, so splitting them breaks it.
- Pod annotations Alloy reads go in the app chart's `podAnnotations`, never `annotations`.

## Grafana (server3)

- Authentik is the only way in: `disable_login_form` closes the browser form and
  `auth.basic.enabled: false` closes HTTP Basic on the API. Because the sidecars authenticated as the
  admin user over Basic, alerts and datasources are loaded by initContainers plus a Reloader restart
  (`configmap.reloader.stakater.com/reload`, anchored regexes). Break-glass: `docs/observability.md`.
- `$__file{}` secrets (`influxdb2-grafana`, `grafana-alerting`) are read at provisioning time, which is
  startup only. A changed secret needs a pod restart.
- Alerting: `alerting-notifications` holds the ONE contact point and the WHOLE policy tree.
  `policies:` replaces, never merges.
- Tempo-backed table panels: never `select()` a numeric span attribute — it crashes the panel and
  looks like a time-range bug. String attributes are safe.

## Verifying a change

Green is not proof. After a change, query the data: `count by (cluster) (kube_pod_status_phase)` in
Prometheus, a narrow `{k8s_cluster_name="…", k8s_namespace_name="…"}` in Loki, or run the
`probe-traffic` skill for an end-to-end trace.
