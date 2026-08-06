# Health Checks for the Custom IoT Apps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Every custom app deployed through the `iot-applications` chart declares `startupProbe`, `readinessProbe` and `livenessProbe`, backed by real health endpoints in the app image, plus a graceful-shutdown path so a rolling update drops zero requests.

**Current state:** No app sets any probe. `gitops/helm-charts/iot-applications/templates/deployment.yaml:149-160` already renders all three when present — the keys are documented in `values.yaml:139-157` and simply never used. Consequences today:

- A container that boots but never finishes wiring MQTT/Mongo still receives traffic — kubelet marks it Ready the moment the process starts.
- A wedged event loop is never restarted. Only a crash (`process.exit`) recovers the pod.
- Rolling updates cut connections: the old pod is SIGTERMed while Traefik still routes to it, and the new pod is added to Endpoints before it can serve.
- **ArgoCD reports the Application `Healthy` as soon as the pods are Running.** Sync-wave 4 (`RootApps`) therefore proceeds on a signal that means nothing. This is the same class of problem as the "green does not mean working" warning in `AGENTS.md`.

**Scope:** three repos, in order — `toolkit-hub` (shared Ts.ED code) → `iot-miniservers` (apps + nginx images) → `homelab` (helm values + chart). Nothing here touches the upstream charts (InfluxDB2, EMQX, MongoDB, Grafana…); those ship their own probes.

---

## Industry standard — what "health check" actually means in Kubernetes

Worth reading once, because most of the design decisions below fall straight out of it.

### The three probes have three different jobs

| Probe | Question it answers | Action on failure | Runs |
| --- | --- | --- | --- |
| `startupProbe` | "Has the process finished booting?" | kill + restart the container | until first success, then never again |
| `readinessProbe` | "Should this pod be in the Service's Endpoints right now?" | remove pod from Endpoints (**no restart**) | for the pod's whole life |
| `livenessProbe` | "Is this process unrecoverably stuck?" | kill + restart the container | after `startupProbe` succeeds |

While a `startupProbe` is defined and unsatisfied, liveness and readiness are **suppressed**. That is the modern replacement for `initialDelaySeconds` guesswork: set a generous `failureThreshold × periodSeconds` budget for boot, then run tight liveness/readiness intervals afterwards.

### Rule 1 — liveness must be shallow

The single most common production incident caused by probes: putting a database check in the liveness probe. The database blips for 40 seconds, every replica of every service fails liveness simultaneously, kubelet restarts them all, they all reconnect at once, and the database — now also facing a thundering herd — stays down. The outage is caused by the health check, not the fault.

**Liveness checks only process-local state.** In practice: "the HTTP server answers". No I/O to anything outside the pod. If a dependency is genuinely unrecoverable without a restart, that is a readiness concern plus an alert, not a liveness kill.

### Rule 2 — readiness is about *this pod*, and about shared fate

Readiness may check dependencies, but note what happens when the dependency is shared: if MongoDB goes down, every replica goes NotReady at once, Endpoints empties, and clients get a connection refused instead of a `503` with a useful body. Whether that is better depends on the app:

- **Good:** the app is a pure proxy over the dependency and can do nothing useful without it → fail readiness, let clients fail fast and retry elsewhere.
- **Bad:** the app can still serve cached/partial responses, or has other endpoints that work → stay Ready, return `503` per-request, alert on the dependency.

Deciding this per app is the point of the analysis table below.

### Rule 3 — endpoints are cheap, unauthenticated, and boring

Kubelet has no credentials. Health endpoints must be reachable without auth, must not touch heavy code paths, must not be logged (they run every few seconds forever), and must not leak infrastructure detail (dependency hostnames, versions, stack traces) since the ingress will expose them.

Two naming conventions dominate:

- Kubernetes' own components use `/healthz`, `/livez`, `/readyz`.
- Application frameworks tend toward `/health`, `/health/live`, `/health/ready` (Spring Boot Actuator, ASP.NET, Quarkus, NestJS Terminus).

For the body, the closest thing to a standard is the IETF draft `draft-inadarei-api-health-check` (`application/health+json`, `{"status": "pass"|"warn"|"fail", "checks": {...}}`). It is a draft, not an RFC, but the shape is widely copied and Grafana/Blackbox tooling parses it fine.

### Rule 4 — probes alone do not give you zero-downtime rollouts

Pod deletion is **concurrent**, not ordered: kubelet sends SIGTERM at the same moment the endpoints controller starts removing the pod from Endpoints, and Traefik only learns about the removal after that propagates. A pod that exits immediately on SIGTERM drops every request in that window. The standard fix, in this order:

1. `preStop` hook that sleeps a few seconds — the pod keeps serving while Endpoints propagates. Kubernetes 1.30+ has a native `sleep` action so no shell is needed (all three clusters run **1.35.2** — `iac/clusters/*/bootstrap/main.tf`).
2. On SIGTERM, flip readiness to failing but keep serving in-flight requests.
3. `terminationGracePeriodSeconds` ≥ preStop sleep + drain time.

### Rule 5 — probes are not monitoring

Probes tell the kubelet what to do. They do not tell *you* anything. The observability side is separate: `kube_pod_status_ready`, `kube_pod_container_status_restarts_total` and probe-failure events, which the existing k8s-monitoring/Alloy stack already collects into server3's Prometheus. Alerting on those is listed under [Follow-ups](#follow-ups) rather than being blocked on here.

---

## Per-app analysis

Five workloads use the `iot-applications` chart. Their dependencies decide their readiness contract.

| App | Where | Runtime deps | Readiness contract | Liveness |
| --- | --- | --- | --- | --- |
| `miot-bridge-api` | server1 · server2, `production` + `sandbox` | MongoDB (mongoose), MQTT broker (EMQX), UDP listener | **mongo + mqtt**. It is a bridge — with either one down, every endpoint fails. Failing readiness is honest | shallow |
| `qr-manager-api` | server1 · server2, `production` + `sandbox` | MongoDB (mongoose) | **mongo**. Every route reads or writes Mongo | shallow |
| `interactive-map-feeder-api` | server1 · server2, `production` + `sandbox` | none inbound; calls outbound HTTP + `sharp` | **static pass**. Its upstreams are third-party HTTP APIs — making readiness depend on someone else's internet endpoint means an outage there deletes your pods from Endpoints for no benefit. Never health-check a dependency you cannot fix | shallow |
| `qr-manager-ui` | server1 · server2, `production` + `sandbox` | nginx serving static SPA | **static pass** — nginx `location = /healthz`. Currently **missing** from `ui/qr-manager-ui/nginx.conf.template` | same endpoint |
| `homelab-dashboard-ui` | server3, `dashboards` | nginx + reverse-proxy to Unifi | **static pass** — `/healthz` **already exists** (`ui/homelab-dashboard-ui/nginx.conf.template`). Do *not* readiness-check the Unifi proxy: the controller rebooting must not delete the dashboard | same endpoint |

Notes that shape the steps:

- **MQTT startup already hard-fails.** `MqttClientProvider` (`apis/miot-bridge-api/src/providers/MqttClientProvider.ts`) rejects the bootstrap promise after 5 consecutive connect errors, and `index.ts` `process.exit(1)`s. So a broker that is down at boot is already a CrashLoop, not a hang — the startup probe is a safety net for the *slow* case, not the failed case. Post-startup reconnects are silent, which is exactly the case readiness must catch.
- **The UDP listener is invisible to HTTP probes.** `miot-bridge-api` exposes a UDP service (`services.udp`, port 4000) through a Traefik `IngressRouteUDP`. A dead UDP socket with a live HTTP server passes every probe here. Covered as a follow-up, not in this plan.
- **`replicas: 1`** on `miot-bridge-api`, `qr-manager-api`, `qr-manager-ui`. Probes make rollouts *correct*, not *seamless*, at one replica — with `maxUnavailable: 0` + `maxSurge: 1` the new pod must go Ready before the old is removed, which is achievable and is the reason readiness matters here at all.

---

## Key decisions

### 1. Paths: `/health/live`, `/health/ready`, plus `/health` for humans

Matches the framework convention rather than the `/livez` k8s-internal one, and gives room for a third informational endpoint. `/health` returns the full check detail; `/health/live` and `/health/ready` return the minimum kubelet needs.

The nginx UIs keep the single `/healthz` that `homelab-dashboard-ui` already ships — a static file server has nothing to distinguish live from ready, and inventing two identical endpoints is noise.

### 2. A shared `HealthController` in `toolkit-hub`, not per-app copies

`tsed/platform` already owns the cross-cutting server concerns (`BaseServer`, middleware stack, logger bridge). Health belongs next to it. Apps opt in the same way they already opt into Swagger:

```ts
mount: { '/': [SwaggerController, HealthController, ...ObjectUtils.values(rest)] }
```

Registration is explicit because each app overrides `mount` in its own `@Configuration`, so anything mounted by `BaseServer`'s decorator would be dropped. One line per app, consistent with the existing `SwaggerController` idiom.

Dependency checks are contributed by the app through a DI token (`HEALTH_CHECKS`), so `toolkit-hub` never imports mongoose or mqtt.

### 3. Hand-rolled controller, not `@tsed/terminus`

`@tsed/terminus` exists and wraps `@godaddy/terminus` with a `@Health("name")` decorator. Rejected:

- It exposes **one** aggregated path (`terminus.path`), so live and ready cannot differ — and rule 1 says they must.
- `@godaddy/terminus` is effectively unmaintained; adding it as a hard dependency of every API for ~80 lines of logic is a poor trade.
- Its graceful-shutdown hooks overlap with the signal handling already present in each app's `index.ts`.

Kept as an alternative if the check registry ever grows enough to want a decorator API.

### 4. Chart gains `terminationGracePeriodSeconds` + `lifecycle`

The probe keys already exist; these two do not, and rule 4 says probes without them still drop requests. Both go into `deployment.yaml` **and** `rollout.yaml` to keep the templates in step, with unit tests, exactly as the Reloader plan did for annotations.

### 5. Probes are declared per app in `base.yaml`, not defaulted in the chart

A chart-wide default would have to guess a path and a port that is wrong for the nginx apps and wrong for anything mounted under a base path. Explicit per-app values also keep the diff reviewable. The chart's `values.yaml` gets a documented copy-paste block instead.

### 6. Health traffic stays out of traces and request logs

Two probes × 3 endpoints × every few seconds is a permanent stream of identical spans and log lines. Filter at the source: `HttpInstrumentation.ignoreIncomingRequestHook` in `packages/otel/src/OpenTelemetryService.ts`, plus the Ts.ED request-log exclusion.

---

## Steps

### Phase A — `toolkit-hub` (repo: `/Users/radoslavirha/dev/irha/toolkit-hub`)

#### A1. Health primitives in `tsed/platform`

- [ ] Create `tsed/platform/src/health/HealthCheck.ts` — the contract an app implements:

```ts
export type HealthStatus = 'pass' | 'warn' | 'fail';

export interface HealthCheckResult {
    readonly status: HealthStatus;
    /** Short, non-sensitive detail. Never include URLs, credentials or stack traces. */
    readonly detail?: string;
}

export interface HealthCheck {
    /** Stable identifier, e.g. 'mongodb', 'mqtt'. Appears in the /health body. */
    readonly name: string;
    check(): Promise<HealthCheckResult> | HealthCheckResult;
}
```

- [ ] Create `tsed/platform/src/health/HealthChecks.ts` — a multi-value DI token apps register into (`injectable`/`InjectMany` pattern already used elsewhere in the repo; follow whatever the current `@tsed/di` version supports). Empty registry must be legal — `interactive-map-feeder-api` registers nothing.
- [ ] Create `tsed/platform/src/health/ShutdownState.ts` — an injectable holding a single `draining` boolean with `beginDrain()`. Default `false`.
- [ ] Create `tsed/platform/src/health/HealthController.ts`:

```ts
@Controller('/health')
@Hidden()                      // keep it out of the Swagger document
export class HealthController {
    @Get('/live')
    live() { /* returns 200 unconditionally — see rule 1 */ }

    @Get('/ready')
    async ready() { /* 503 when draining, or when any registered check fails */ }

    @Get('/')
    async detail() { /* full { status, checks } body, 200 or 503 */ }
}
```

  - `/live` does **no** I/O and never consults the registry. Reaching the handler is the proof.
  - `/ready` returns `503` immediately if `ShutdownState.draining`, then evaluates every registered check with a **hard 2s timeout each** (a check that hangs must fail, not stall the probe past its `timeoutSeconds`).
  - Body shape follows `application/health+json`: `{"status":"pass","checks":{"mongodb":{"status":"pass"}}}`. Names only — no URLs, no versions.
- [ ] Export all four from `tsed/platform/src/index.ts`.
- [ ] Unit tests (vitest, matching the existing `*.spec.ts` style): live is 200 with a failing check registered; ready is 503 with a failing check; ready is 503 while draining; ready is 503 when a check exceeds its timeout; empty registry is 200; body contains no field other than `status`/`checks`.

#### A2. Drain on SIGTERM

- [ ] Give `BaseServer` a `$beforeShutdown`-equivalent hook (or expose `ShutdownState` for the app bootstrap to call) that sets `draining = true` **before** `platform.stop()` runs. Verify against the installed Ts.ED version which lifecycle hook fires first on `platform.stop()`; if none fires early enough, call `beginDrain()` from the signal handler in each app's `index.ts` before `platform.stop()`.
- [ ] Test: after `beginDrain()`, `/health/ready` is 503 and `/health/live` is still 200.

#### A3. Release

- [ ] Changeset + version bump for `@radoslavirha/tsed-platform` (currently `3.0.5`). Minor — additive only.
- [ ] `pnpm run verify` at the repo root (lint + build + test), then publish per the repo's normal release flow.

### Phase B — `iot-miniservers` (repo: `/Users/radoslavirha/dev/irha/iot-miniservers`)

#### B1. `miot-bridge-api`

- [ ] Bump `@radoslavirha/tsed-platform` to the Phase A version.
- [ ] Add `src/health/MongoHealthCheck.ts` — inject `MongooseService`, return `pass` when `mongooseService.get()?.readyState === 1`, else `fail` with `detail` = the readyState name. No ping query: `readyState` is free, a `ping` is a round trip every few seconds forever.
- [ ] Add `src/health/MqttHealthCheck.ts` — inject `MqttClientProvider`, return `pass` when the client is non-null and `client.connected`. **Return `pass` when the provider resolved to `null`** (MQTT disabled by config) — a disabled feature is not a failure.
- [ ] Register both into `HEALTH_CHECKS` in `src/providers/index.ts` (or a new `src/health/index.ts` imported by `Server.ts`, matching how providers are wired today).
- [ ] Add `HealthController` to the `mount` array in `src/Server.ts`.
- [ ] Call `beginDrain()` in the `SIG_EVENTS` handler in `src/index.ts`, before `platform.stop()`.
- [ ] Integration test alongside `src/Server.integration.spec.ts`: `/health/live` 200, `/health/ready` reflects a stubbed-down mongo.

#### B2. `qr-manager-api`

- [ ] Same as B1 minus MQTT: bump, `MongoHealthCheck`, register, mount `HealthController`, drain on SIGTERM, test.

#### B3. `interactive-map-feeder-api`

- [ ] Bump, mount `HealthController`, drain on SIGTERM. **No checks registered** — see the analysis table. Add a one-line comment in `Server.ts` saying why, so nobody "fixes" it later by adding an upstream HTTP check.

#### B4. `qr-manager-ui` — add the missing nginx health location

- [ ] `ui/qr-manager-ui/nginx.conf.template` — add **above** the `${NGINX_BASE_PATH}` locations, at an absolute path so the probe does not depend on the base path:

```nginx
    # k8s liveness / readiness probe. Absolute path, independent of NGINX_BASE_PATH.
    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 'ok';
    }
```

- [ ] Confirm `location = /healthz` (exact match) wins over the `location ${NGINX_BASE_PATH}/` prefix match — nginx evaluates exact matches first, so it does even when `NGINX_BASE_PATH` is `/`.

#### B5. `homelab-dashboard-ui`

- [ ] No image change — `/healthz` already exists. Verify it is still there and unauthenticated before wiring the probe in Phase C.

#### B6. Keep health traffic out of telemetry

- [ ] `packages/otel/src/OpenTelemetryService.ts` — pass `ignoreIncomingRequestHook` to `HttpInstrumentation` dropping requests whose URL starts with `/health`. Keep it a constant next to the instrumentation list so it is greppable.
- [ ] Exclude the same paths from request logging (`@tsed/platform-log-request` is imported by `BaseServer`; check whether the exclusion belongs there in `toolkit-hub` instead — if so, fold it into Phase A1 and note it here as done).
- [ ] Verify no `/health` spans reach Tempo after deploy (see verification).

#### B7. Release

- [ ] Changesets for the three APIs and `qr-manager-ui`. Patch/minor per changeset conventions.
- [ ] `pnpm run verify`. Merge → the release workflow builds images and the deploy action bumps `image.tag` in this repo via each app's `deploy.json`.

### Phase C — `homelab` (this repo)

#### C1. Chart: graceful shutdown support

- [ ] `gitops/helm-charts/iot-applications/templates/deployment.yaml` — in the pod spec, after `imagePullSecrets`:

```yaml
      {{- with $application.terminationGracePeriodSeconds }}
      terminationGracePeriodSeconds: {{ . }}
      {{- end }}
```

- [ ] Same file, in the main container block after `startupProbe`:

```yaml
          {{- with $application.lifecycle }}
          lifecycle:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

- [ ] Apply both blocks identically to `templates/rollout.yaml`.
- [ ] Document both keys in `gitops/helm-charts/iot-applications/values.yaml`, next to the existing probe comments (lines ~139-157), including the ready-to-copy probe block from C2 and a one-line pointer to this plan.
- [ ] Extend `tests/deployment_test.yaml`: `lifecycle` rendered when set / absent when unset; `terminationGracePeriodSeconds` likewise; probes still render (guards against a regression while editing around them).
- [ ] `helm unittest gitops/helm-charts/iot-applications` — CI runs the same via `.github/workflows/helm-chart-ci.yaml`.

#### C2. Probe values — the three APIs

- [ ] Add to `gitops/helm-values/apps/miot-bridge-api/base.yaml`, `qr-manager-api/base.yaml`, `interactive-map-feeder-api/base.yaml` under the app key. `port: http` refers to the container port name the chart derives from the `services` map key, so this stays correct if the port number ever changes:

```yaml
    # Boot budget: 5s × 24 = 120s. Liveness/readiness are suppressed until this passes.
    startupProbe:
      httpGet:
        path: /health/live
        port: http
      periodSeconds: 5
      failureThreshold: 24
      timeoutSeconds: 2

    # Shallow by design — no dependency I/O. A Mongo/MQTT outage must not restart pods.
    livenessProbe:
      httpGet:
        path: /health/live
        port: http
      periodSeconds: 10
      failureThreshold: 3
      timeoutSeconds: 2

    # Checks dependencies. Failing here only removes the pod from Endpoints.
    readinessProbe:
      httpGet:
        path: /health/ready
        port: http
      periodSeconds: 5
      failureThreshold: 3
      successThreshold: 1
      timeoutSeconds: 3

    # Keep serving while Endpoints removal propagates to Traefik (rule 4).
    terminationGracePeriodSeconds: 30
    lifecycle:
      preStop:
        sleep:
          seconds: 10

    # At replicas: 1, this is what makes a rollout gapless — the new pod must pass
    # readiness before the old one is torn down.
    strategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 1
        maxUnavailable: 0
```

- [ ] `readinessProbe.timeoutSeconds: 3` is deliberately above the controller's 2s per-check timeout so a slow check reports `fail` with detail rather than being cut off as a probe timeout with no signal.

#### C3. Probe values — the two UIs

- [ ] `gitops/helm-values/apps/qr-manager-ui/base.yaml` and `gitops/helm-values/server3/homelab-dashboard-ui.yaml` — same block with `path: /healthz` for all three probes and a shorter boot budget (nginx starts in under a second):

```yaml
    startupProbe:
      httpGet: { path: /healthz, port: http }
      periodSeconds: 2
      failureThreshold: 15
    livenessProbe:
      httpGet: { path: /healthz, port: http }
      periodSeconds: 10
      failureThreshold: 3
    readinessProbe:
      httpGet: { path: /healthz, port: http }
      periodSeconds: 5
      failureThreshold: 3
    terminationGracePeriodSeconds: 30
    lifecycle:
      preStop:
        sleep:
          seconds: 5
```

- [ ] Do **not** add a readiness dependency on the Unifi controller for `homelab-dashboard-ui`.

#### C4. Roll out sandbox first

- [ ] Commit C1-C3 with the image tags still pointing at the pre-health versions **only if** the probes would already pass — they would not, `/health/*` returns 404 on the old images. So: land the Phase B image bumps for `sandbox` first, confirm, then `production`. If in doubt, put the probe values in `sandbox.yaml` first and promote to `base.yaml` after the production tags catch up.

### Verification

`AGENTS.md`: green sync status is not evidence. Query the actual behaviour.

- [ ] Endpoints answer, from inside the cluster:
      `kubectl exec -n sandbox deploy/api-iot-qr-manager-api -- wget -qO- localhost:4000/health/ready`
- [ ] Probes are attached where intended:
      `kubectl get deploy -n sandbox -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].livenessProbe.httpGet.path}{"\n"}{end}'`
- [ ] **Liveness is genuinely shallow.** Scale MongoDB to 0 in `sandbox`, wait 2 minutes, confirm: pods go `READY 0/1`, `RESTARTS` stays put. A restart here means a dependency check leaked into liveness — the exact failure mode rule 1 warns about. Scale Mongo back.
- [ ] **Readiness recovers** without intervention once Mongo is back.
- [ ] **Rollout is gapless.** Run `kubectl rollout restart deploy/<app> -n sandbox` while curling the ingress in a loop from another shell; expect zero non-200s. Without the preStop hook this test fails — that is what it is for.
- [ ] **ArgoCD health now means something:** during the restart the Application should transition to `Progressing`, not sit at `Healthy`.
- [ ] **No telemetry noise:** query Tempo for spans with `http.route =~ "/health.*"` over the last 15 minutes — expect none. Same for Loki: no request-log lines for `/health`.
- [ ] Repeat the endpoint check on `homelab-dashboard-ui` (server3) and `qr-manager-ui`.
- [ ] Only then promote to `production` and re-run the endpoint + rollout checks there.

### Documentation

- [ ] `docs/architecture.md` — no new rows (no new app), but note in the custom-apps section that all five declare probes.
- [ ] `AGENTS.md` — under the `iot-applications` chart notes, record the new `lifecycle` / `terminationGracePeriodSeconds` keys and the probe convention (`/health/live`, `/health/ready`, `/healthz` for the nginx UIs).
- [ ] `docs/iot-overview.md` — one paragraph: what each probe means for these apps, and the deliberate choice that a Mongo/MQTT outage degrades readiness but never restarts pods.
- [ ] `iot-miniservers` `AGENTS.md` + the app template docs — how a new API opts in (mount `HealthController`, register checks) so onboarding does not skip it.
- [ ] Run the `sync-docs` skill last (it chains `sync-obsidian`).

---

## Follow-ups

Deliberately out of scope; each is worth its own plan.

- **UDP liveness for `miot-bridge-api`.** The HTTP probes say nothing about the UDP listener. Options: an `exec` probe that sends a UDP datagram to `localhost:4000` and checks the reply, or a `udp.lastPacketAt` gauge scraped from OTel with a Grafana alert. The metric is cheaper and does not risk restart loops.
- **Alerting on probe state.** `kube_pod_status_ready` and `kube_pod_container_status_restarts_total` already land in server3's Prometheus via k8s-monitoring. A Grafana alert on "custom app NotReady > 5m" or "restarts > 3 in 15m" converts probes from self-healing into visibility.
- **PodDisruptionBudgets.** With `replicas: 1` a PDB cannot help; it becomes meaningful if any app is scaled to ≥2 (`interactive-map-feeder-api` already runs 2 and could take `minAvailable: 1` today).
- **External blackbox probing.** Probes are inside the cluster. Blackbox Exporter hitting the Traefik hostnames from server3 would catch ingress, DNS and certificate faults that every in-cluster probe passes straight through.
- **MQTT/UDP-only workloads generally.** If a future app has no HTTP server, it needs an `exec` or `tcpSocket` probe instead. The chart supports both today — only the values differ.

## Alternatives considered

| Option | Verdict |
| --- | --- |
| **Shared `HealthController` in `tsed/platform` + per-app checks** | **Chosen.** One implementation, no duplicated logic, apps only contribute what they know about. Matches the existing `SwaggerController` mounting idiom. |
| `@tsed/terminus` | Rejected — single aggregated path cannot separate live from ready, and `@godaddy/terminus` is unmaintained. See decision 3. |
| Copy a health controller into each API | Rejected — three copies drifting apart, and a fourth app would start from whichever copy it was cloned from. |
| `exec` probes running `wget` in the container | Rejected — spawns a process every few seconds and depends on a binary being present in the image. `httpGet` is free and handled by kubelet. |
| `tcpSocket` probes | Rejected as the primary mechanism — proves a listener exists, not that the app works. Reasonable only for the future UDP/MQTT-only case. |
| Readiness that checks upstream third-party HTTP APIs (`interactive-map-feeder-api`) | Rejected — an outage you cannot fix would remove your own pods from Endpoints. Alert on the upstream instead. |
| Chart-wide default probes | Rejected — the correct path and port differ between the nginx UIs and the Ts.ED APIs; a wrong default silently CrashLoops a new app. Documented copy-paste block in `values.yaml` instead. |
| Probes only, no `preStop`/grace period | Rejected — pod deletion and Endpoints removal are concurrent, so rollouts still drop requests. See rule 4. |
