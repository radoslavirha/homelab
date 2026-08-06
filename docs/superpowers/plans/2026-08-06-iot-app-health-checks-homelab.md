# Health Checks for the Custom IoT Apps — homelab side only

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Scope:** this repository only — the `iot-applications` chart and the app helm values. The application images are assumed to already expose the health endpoints described under [Assumed contract](#assumed-contract).

**Companion plan:** [`2026-08-06-iot-app-health-checks.md`](2026-08-06-iot-app-health-checks.md) covers the whole picture across `toolkit-hub`, `iot-miniservers` and this repo, and carries the reasoning — probe taxonomy, why liveness must be shallow, why readiness must not depend on third-party upstreams, why probes alone do not give gapless rollouts. Read it once before executing this one; it is not repeated here beyond the short version in each step's comment.

**Goal:** every workload deployed through `gitops/helm-charts/iot-applications` declares `startupProbe`, `readinessProbe` and `livenessProbe`, and shuts down without dropping requests.

**Current state:** the chart renders all three probe keys already (`templates/deployment.yaml:149-160`, `templates/rollout.yaml:139-148`) and documents them in `values.yaml:139-157`. No app sets any of them. The chart has no `lifecycle` or `terminationGracePeriodSeconds` support at all.

---

## Assumed contract

This plan is **blocked** until each image below answers on the listed path. Verify before starting — a probe against a 404 CrashLoops the app.

| Workload | Values file | Live path | Ready path | Semantics expected from the image |
| --- | --- | --- | --- | --- |
| `miot-bridge-api` | `gitops/helm-values/apps/miot-bridge-api/base.yaml` | `/health/live` | `/health/ready` | live = process only. ready = MongoDB `readyState` + MQTT connected |
| `qr-manager-api` | `gitops/helm-values/apps/qr-manager-api/base.yaml` | `/health/live` | `/health/ready` | live = process only. ready = MongoDB `readyState` |
| `interactive-map-feeder-api` | `gitops/helm-values/apps/interactive-map-feeder-api/base.yaml` | `/health/live` | `/health/ready` | both static pass — no registered checks (upstreams are third-party) |
| `qr-manager-ui` | `gitops/helm-values/apps/qr-manager-ui/base.yaml` | `/healthz` | `/healthz` | nginx `location = /healthz`, **absolute path, not under `NGINX_BASE_PATH`** |
| `homelab-dashboard-ui` | `gitops/helm-values/server3/homelab-dashboard-ui.yaml` | `/healthz` | `/healthz` | nginx `location = /healthz` — already present in the image today |

Additional expectations, all of them the app side's responsibility:

- **Readiness flips to 503 on SIGTERM** while in-flight requests keep being served. Without this the `preStop` sleep added below buys time but the pod is still in Endpoints for the whole grace period.
- **`/health*` is excluded from traces and request logs**, otherwise a permanent stream of identical spans hits Tempo.
- Health bodies contain no URLs, credentials or stack traces — the ingress exposes these paths publicly (`stripPrefix: true` on the APIs means `https://api.<cluster>.home/iot/qr-manager/health/ready` reaches `/health/ready`).

**Gate — run this before step 1**, per app and cluster, replacing the deployment name:

```bash
kubectl exec -n sandbox deploy/api-iot-qr-manager-api -- wget -qO- -S localhost:4000/health/ready
kubectl exec -n sandbox deploy/api-iot-qr-manager-api -- wget -qO- -S localhost:4000/health/live
```

A 404 on either means the image is not ready — stop and finish the app-side plan first.

---

## Steps

### 1. Chart — graceful shutdown support

Probes without these two keys still drop requests: pod deletion and Endpoints removal are concurrent, so a pod that exits on SIGTERM dies while Traefik still routes to it. All three clusters run Kubernetes **1.35.2** (`iac/clusters/*/bootstrap/main.tf`), so the native `lifecycle.preStop.sleep` action is available — no shell binary needed in the image.

- [ ] `gitops/helm-charts/iot-applications/templates/deployment.yaml` — add to the **pod spec**, immediately after the `imagePullSecrets` block (~line 54, before `initContainers`):

```yaml
      {{- with $application.terminationGracePeriodSeconds }}
      terminationGracePeriodSeconds: {{ . }}
      {{- end }}
```

- [ ] Same file — add to the **main container**, immediately after the `startupProbe` block (~line 160, before `volumeMounts`):

```yaml
          {{- with $application.lifecycle }}
          lifecycle:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

- [ ] `gitops/helm-charts/iot-applications/templates/rollout.yaml` — apply both blocks at the equivalent positions (pod spec after `imagePullSecrets` ~line 50; container after `startupProbe` ~line 151). The two templates must stay in step even though Argo Rollouts is not installed in any cluster.

### 2. Chart — document the new keys

- [ ] `gitops/helm-charts/iot-applications/values.yaml` — extend the commented block around the existing probe keys (lines ~139-157) with a copy-pasteable reference. Deliberately **not** chart defaults: the correct path and boot budget differ between the nginx UIs and the Ts.ED APIs, and a wrong default silently CrashLoops the next app onboarded.

```yaml
#     # livenessProbe — MUST stay shallow: process-local only, no dependency I/O.
#     # A dependency check here turns one database blip into a fleet-wide restart storm.
#     livenessProbe:
#       httpGet:
#         path: /health/live
#         # port refers to a key from the services map, rendered as the container port name.
#         port: http
#       periodSeconds: 10
#       failureThreshold: 3
#       timeoutSeconds: 2

#     # readinessProbe — may check hard dependencies. Failure only removes the pod
#     # from the Service Endpoints; it never restarts the container.
#     readinessProbe:
#       httpGet:
#         path: /health/ready
#         port: http
#       periodSeconds: 5
#       failureThreshold: 3
#       timeoutSeconds: 3

#     # startupProbe — the boot budget (periodSeconds × failureThreshold).
#     # Liveness and readiness are suppressed until it passes once, which is the
#     # modern replacement for initialDelaySeconds guesswork.
#     startupProbe:
#       httpGet:
#         path: /health/live
#         port: http
#       periodSeconds: 5
#       failureThreshold: 24

#     # terminationGracePeriodSeconds is the SIGTERM → SIGKILL budget.
#     # Must exceed the preStop sleep plus the app's own drain time.
#     terminationGracePeriodSeconds: 30

#     # lifecycle hooks. preStop.sleep (native action, Kubernetes 1.30+) keeps the pod
#     # serving while its removal from Endpoints propagates to Traefik — without it a
#     # rolling update drops requests even with correct probes.
#     lifecycle:
#       preStop:
#         sleep:
#           seconds: 10
```

- [ ] Add a one-line pointer to this plan and its companion above that block.

### 3. Chart — tests

- [ ] Extend `gitops/helm-charts/iot-applications/tests/deployment_test.yaml`, following the existing `set:` + `asserts:` style:
  - `lifecycle` rendered under the container when set; absent when unset
  - `terminationGracePeriodSeconds` rendered under the pod spec when set; absent when unset
  - all three probes still render when set, and are absent when unset — a regression guard, since the new container block is inserted right next to them
- [ ] Check whether `tests/__snapshot__` holds a snapshot covering the container or pod spec; update it if so.
- [ ] `helm unittest gitops/helm-charts/iot-applications` — CI runs the same via `.github/workflows/helm-chart-ci.yaml` (helm-unittest v0.4.4).

### 4. Values — the three Ts.ED APIs

Add to each app key in `gitops/helm-values/apps/miot-bridge-api/base.yaml`, `gitops/helm-values/apps/qr-manager-api/base.yaml` and `gitops/helm-values/apps/interactive-map-feeder-api/base.yaml`. Identical block for all three — the difference in behaviour lives in the image, not here.

```yaml
    # Boot budget: 5s × 24 = 120s. Liveness and readiness stay suppressed until this passes.
    startupProbe:
      httpGet:
        path: /health/live
        port: http
      periodSeconds: 5
      failureThreshold: 24
      timeoutSeconds: 2

    # Shallow by design — no dependency I/O. A MongoDB or MQTT outage must degrade
    # readiness, never restart pods.
    livenessProbe:
      httpGet:
        path: /health/live
        port: http
      periodSeconds: 10
      failureThreshold: 3
      timeoutSeconds: 2

    # Checks dependencies. Failing here only removes the pod from Endpoints.
    # timeoutSeconds is above the app's own per-check timeout so a slow dependency
    # reports a failed check with detail rather than being cut off as a probe timeout.
    readinessProbe:
      httpGet:
        path: /health/ready
        port: http
      periodSeconds: 5
      failureThreshold: 3
      successThreshold: 1
      timeoutSeconds: 3

    # Keep serving while Endpoints removal propagates to Traefik.
    terminationGracePeriodSeconds: 30
    lifecycle:
      preStop:
        sleep:
          seconds: 10

    # At replicas: 1 this is what makes a rollout gapless — the new pod must pass
    # readiness before the old one is torn down.
    strategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 1
        maxUnavailable: 0
```

- [ ] `port: http` is the key from each app's `services` map, which the chart renders as the container port name. Confirm each of the three apps uses `services.http` (they do today, `targetPort: 4000`) so the name resolves.
- [ ] `interactive-map-feeder-api` already runs `replicas: 2`; the `strategy` block is still correct there.
- [ ] Do not add a readiness dependency on the third-party HTTP upstreams that `interactive-map-feeder-api` calls. Its `/health/ready` is a static pass on purpose.

### 5. Values — the two nginx UIs

nginx starts in well under a second, so the boot budget is much shorter, and a static file server has nothing that distinguishes live from ready — one path serves both.

- [ ] Add to `gitops/helm-values/apps/qr-manager-ui/base.yaml` and `gitops/helm-values/server3/homelab-dashboard-ui.yaml`:

```yaml
    # nginx serves a static SPA — /healthz is an absolute path independent of
    # NGINX_BASE_PATH, and there is no live/ready distinction to make.
    startupProbe:
      httpGet:
        path: /healthz
        port: http
      periodSeconds: 2
      failureThreshold: 15
    livenessProbe:
      httpGet:
        path: /healthz
        port: http
      periodSeconds: 10
      failureThreshold: 3
    readinessProbe:
      httpGet:
        path: /healthz
        port: http
      periodSeconds: 5
      failureThreshold: 3
    terminationGracePeriodSeconds: 30
    lifecycle:
      preStop:
        sleep:
          seconds: 5
    strategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 1
        maxUnavailable: 0
```

- [ ] `homelab-dashboard-ui` reverse-proxies to the Unifi controller (`location /proxy/network/`). Do **not** make readiness depend on it — a controller reboot must not delete the dashboard from Endpoints.

### 6. Roll out sandbox before production

The values in steps 4-5 sit in `base.yaml`, which applies to both namespaces at once. If the `production` image tags are still behind the health-endpoint release while `sandbox` is ahead, the probes will 404 in production and CrashLoop it.

- [ ] Compare `image.tag` in each app's `sandbox.yaml` and `production.yaml` against the first release that carries the health endpoints.
- [ ] If both are current: land the block in `base.yaml` as written.
- [ ] If production lags: put the block in `sandbox.yaml` only, verify per below, then move it to `base.yaml` once the production tag catches up. Leave a `TODO` comment naming the required tag so the split is not forgotten.

### 7. Verification

Per `AGENTS.md`, ArgoCD reporting `Synced`/`Healthy` proves the manifests applied, nothing more. Query the behaviour.

- [ ] Probes attached where intended, per cluster and namespace:

```bash
kubectl get deploy -n sandbox -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].livenessProbe.httpGet.path}{"\t"}{.spec.template.spec.containers[0].readinessProbe.httpGet.path}{"\n"}{end}'
```

- [ ] `preStop` and grace period landed:

```bash
kubectl get deploy -n sandbox -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.terminationGracePeriodSeconds}{"\t"}{.spec.template.spec.containers[0].lifecycle}{"\n"}{end}'
```

- [ ] All pods reach `READY 1/1` and stay there. `kubectl get pods -n sandbox -w` for a few minutes — a probe misconfiguration shows up as a restart loop, not as an ArgoCD error.
- [ ] **Liveness is genuinely shallow.** Scale MongoDB to 0 in `sandbox`, wait 2 minutes:

```bash
kubectl scale statefulset mongodb -n mongodb --replicas=0     # ASK the operator first — see AGENTS.md
kubectl get pods -n sandbox -w
```

  Expected: `miot-bridge-api` and `qr-manager-api` go `READY 0/1`, `RESTARTS` unchanged. A restart means a dependency check leaked into the liveness endpoint — that is an app-side bug, report it rather than papering over it here. Scale MongoDB back and confirm readiness recovers on its own with no pod deletion.
- [ ] **Rollout is gapless.** In one shell curl the ingress in a loop; in another:

```bash
kubectl rollout restart deploy/api-iot-qr-manager-api -n sandbox
```

  Expect zero non-200 responses. Without the `preStop` hook this test fails — it is the reason step 1 exists.
- [ ] **ArgoCD health now carries signal:** during that restart the Application must pass through `Progressing` instead of sitting at `Healthy` the whole time.
- [ ] **No telemetry noise:** via the Grafana MCP, query Tempo for spans matching `/health` over the last 15 minutes and Loki for request-log lines on the same paths. Both should be empty. If not, the exclusion is missing app-side — record it, it does not block this plan.
- [ ] Repeat the probe-attachment and rollout checks for `homelab-dashboard-ui` on server3 (namespace `dashboards`).
- [ ] Only then promote to `production` and re-run the probe-attachment and rollout checks there.

### 8. Documentation

- [ ] `AGENTS.md` — in the `iot-applications` chart notes, record the new `lifecycle` and `terminationGracePeriodSeconds` keys and the probe path convention (`/health/live` + `/health/ready` for the Ts.ED APIs, `/healthz` for the nginx UIs).
- [ ] `docs/architecture.md` — no new rows (no new app); note in the custom-apps section that all five workloads declare probes.
- [ ] `docs/iot-overview.md` — a short paragraph: what each probe means for these apps, and the deliberate choice that a MongoDB or MQTT outage degrades readiness but never restarts pods.
- [ ] Run the `sync-docs` skill last (it chains `sync-obsidian`).

---

## Out of scope

Tracked in the companion plan's follow-ups: UDP liveness for `miot-bridge-api` (HTTP probes are blind to its UDP listener), alerting on `kube_pod_status_ready` / restart counts, external blackbox probing of the Traefik hostnames, and PodDisruptionBudgets.

Also out of scope here by definition: everything inside the app images, and the upstream charts (InfluxDB2, EMQX, MongoDB, Grafana, Loki, Tempo, Traefik…) which ship their own probes already.
