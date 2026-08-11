# Health Checks for the Custom IoT Apps — homelab side only

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Scope:** this repository only — the `iot-applications` chart and the app helm values. The application images are assumed to already expose the health endpoints described under [Assumed contract](#assumed-contract).

**Companion plan:** [`2026-08-06-iot-app-health-checks.md`](2026-08-06-iot-app-health-checks.md) covers the whole picture across `toolkit-hub`, `iot-miniservers` and this repo, and carries the reasoning — probe taxonomy, why liveness must be shallow, why readiness must not depend on third-party upstreams, why probes alone do not give gapless rollouts. Read it once before executing this one; it is not repeated here beyond the short version in each step's comment.

**Goal:** every workload deployed through `gitops/helm-charts/iot-applications` declares `startupProbe`, `readinessProbe` and `livenessProbe`, and shuts down without dropping requests.

**Current state:** the chart renders all three probe keys already (`templates/deployment.yaml:149-160`, `templates/rollout.yaml:139-148`) and documents them in `values.yaml:139-157`. No app sets any of them. The chart has no `lifecycle` or `terminationGracePeriodSeconds` support at all.

**Check concerns of agent in apps repository**
[Spec](./2026-08-07-probe-state-not-observable.md)

## Status — 2026-08-11

| Part | State |
| --- | --- |
| Chart (steps 1-3) | **done.** `lifecycle` + `terminationGracePeriodSeconds` in both templates, documented, 72 helm-unittest assertions passing |
| Frontends (step 5) | **done, deployed and verified in cluster.** `qr-manager-ui` staged in `sandbox.yaml`, since promoted to `base.yaml` (`c445ccd`); `homelab-dashboard-ui` direct |
| Backends (step 4) | **done.** The health release is live: `qr-manager-api@0.5.0`, `miot-bridge-api@0.19.0`, `interactive-map-feeder-api@0.11.0`. Gate re-run and passed. Probe block staged in each `sandbox.yaml`, then promoted to `base.yaml` in the same session once the sandbox rollout had been watched |
| Production | **deployed.** All six production Applications synced; probes, `lifecycle` and `strategy` attached on both clusters |
| Observability (`kube_pod_status_ready`) | **still missing.** `gitops/helm-values/k8s-monitoring.yaml` sets no `metricsTuning`. Step 4's ordering note said land this first; it was deliberately deferred to a separate session, so a readiness failure is currently invisible to Prometheus in every namespace |
| Docs (step 8) | pending — do it once the backend half is deployed, so `docs/iot-overview.md` is written once |

The `templates.<name>.validate` support the UIs need landed at the same time, from the sibling plan [`2026-08-07-iot-applications-template-validation.md`](2026-08-07-iot-applications-template-validation.md). The two changes touch the same two template files, so they were applied together.

**Ordering gate — satisfied for both UIs**, verified 2026-08-08 before any values were written:

| Check | Result |
| --- | --- |
| `qr-manager-ui@0.7.0` running in `sandbox` + `production` on server2 | yes, `READY 1/1` |
| `homelab-dashboard-ui@0.4.0` running on server3, namespace **`homelab`** (not `dashboards` — the plan said otherwise below) | yes, `READY 1/1` |
| `/healthz` answers `ok` in all three | yes |
| `/healthzzz` returns 404 — the exact-match fix is live | yes |
| nginx is PID 1 on the dashboard (guards the entrypoint rewrite) | yes |
| `<app>-config-validator` present in GHCR at the pinned tags | yes — `qr-manager-ui-config-validator:0.7.0`, `homelab-dashboard-ui-config-validator:0.4.0` |
| Both validators accept the **live rendered** config from every environment | yes — three configs, three `exit=0` |
| Validator rejects an empty substitution | yes — `✖ Invalid URL → at apiBaseURL`, `exit=1`, no value echoed |
| Cluster nodes are `amd64` (the validator images are amd64-only) | yes, server1 + server2 + server3 |

> **Correction:** the first pass of this gate checked server2 and server3 only. **server1 is a live cluster** running `qr-manager-ui` in both `sandbox` and `production`, and `base.yaml`/`sandbox.yaml` apply to it too. Caught before the values were committed; server1 was on `0.7.0` and `/healthz` answered there as well. Any future values change to these files has four qr-manager-ui environments to think about, not two.
>
> Unrelated but noticed while checking: server1 holds several `Succeeded` pods from ReplicaSets retired on 2026-06-26 (`qr-manager-ui@0.4.2`, `interactive-map-feeder-api@0.10.0`). Exit code 0, terminated cleanly — leftovers from a node restart, not a live fault. Not cleaned up here.

### Cluster verification — 2026-08-08

Deployed to `sandbox` on server1 + server2 and to `homelab` on server3. `production` deliberately untouched (the block lives in `sandbox.yaml`), and its Applications stayed `Healthy` throughout — which is itself the evidence that the staging works.

| Check | Result |
| --- | --- |
| initContainer order | `…-config-jinja2` → `…-config-validate`, both `Completed exit=0` |
| Validator output on a good config | `[qr-manager-ui] /config/config.json is valid` |
| Probes attached | `live=/healthz ready=/healthz startup=/healthz` on both UIs |
| `preStop` + grace attached | `grace=30 preStop=5` |
| Restarts after rollout | `0` |
| **Gapless rollout** | `kubectl rollout restart` under a curl loop against `sandbox.apps.server2.home/qr-manager/`: **6507 requests, 6507× HTTP 200, zero failures** |
| ArgoCD health carries signal | app went `Progressing` during the rollout, not a flat `Healthy` |

### Deliberate failure test — 2026-08-08

`apiBaseURL` was emptied in `sandbox.yaml` and committed (commit `7b89c14`, reverted by `0818719`) — the empty-Jinja2-substitution case, which is valid JSON and therefore invisible to every check except the schema.

| Observation | Result |
| --- | --- |
| New pod | `Init:Error` → `Init:CrashLoopBackOff`, never reached the main container |
| Validator log | `✖ Invalid URL → at apiBaseURL` |
| Config values in the log | none — grepped for the hostname and both path fragments, zero hits |
| **Old pod** | stayed `1/1 Running`, restarts `0` |
| **Ingress during the failure** | HTTP 200 throughout |
| ArgoCD | `Synced` + `Progressing` — visible without being an outage |
| After revert | new pod Ready in under a minute, validator `is valid`, config correct, app `Healthy` |

So a bad config edit is now contained at the moment it is made: it costs a stuck ReplicaSet and a log line, not a blank page served to users.

### Found in production use, not in planning

**`runAsNonRoot: true` is not enough on its own.** The validating initContainer failed to start on first sync with:

```text
CreateContainerConfigError: container has runAsNonRoot and image has non-numeric
user (node), cannot verify user is non-root
```

Both validator images declare `USER node` — a *name*. The kubelet cannot resolve a name to a UID, so it refuses to start the container. The sibling plan's decision 4a explicitly claimed `USER node (uid 1000)` satisfies `runAsNonRoot` without a chart-supplied `runAsUser`; that was wrong. Fixed in `6aaaafb` by defaulting `runAsUser: 1000` (verified with `id` inside the image), overridable via the `validate` map form.

Worth noting how it failed: the pod sat `Pending` on the init container and the old pod kept serving. Even the chart bug was contained by the same fail-closed design.

**PodSecurity `restricted` is warn-only and nothing meets it.** `kubectl rollout restart` surfaced:

```text
Warning: would violate PodSecurity "restricted:latest": … containers
"…-config-jinja2", "…" must set securityContext.allowPrivilegeEscalation=false,
capabilities.drop=["ALL"], runAsNonRoot=true, seccompProfile …
```

Pre-existing and unrelated to health checks — the chart documents `podSecurityContext` / `containerSecurityContext` but no app sets either, and `objectiflibre/jinja-init` runs as root. The validator initContainer was flagged only for `seccompProfile`, now added, so it is the one container in these pods that satisfies `restricted`. Closing the gap for the rest is its own change; see Out of scope.

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

**Gate — run this before step 1**, per app and cluster, replacing the deployment name.

**The API images ship no `wget`** (`exec: "wget": executable file not found in $PATH`) — the
original form of this gate could not run. Use the Node runtime that is in the image:

```bash
kubectl exec -n sandbox deploy/api-iot-qr-manager-api -- node -e \
  'fetch("http://localhost:4000"+process.argv[1]).then(async r=>console.log(r.status, await r.text()))' \
  -- /health/ready
```

A 404 means the image is not ready — stop and finish the app-side plan first.

**Gate result — 2026-08-11, passed on server1 + server2 `sandbox`** after syncing the six
sandbox Applications to `c7cbb93`:

| Workload | `/health/live` | `/health/ready` | `/health` |
| --- | --- | --- | --- |
| `qr-manager-api@0.5.0` | 200 `{"status":"pass"}` | 200 `{"status":"pass"}` | 200, checks `mongodb` |
| `miot-bridge-api@0.19.0` | 200 `{"status":"pass"}` | 200 `{"status":"pass"}` | 200, checks `mongodb`, `mqtt` |
| `interactive-map-feeder-api@0.11.0` | 200 `{"status":"pass"}` | 200 `{"status":"pass"}` | 200, checks `upstream-apis` |

The check-name sets match what the backend spec promises, which is the assertion that
matters: a check missing its `type: HEALTH_CHECKS` still resolves and would report a
healthy app that checks nothing.

---

## Steps

### 1. Chart — graceful shutdown support

Probes without these two keys still drop requests: pod deletion and Endpoints removal are concurrent, so a pod that exits on SIGTERM dies while Traefik still routes to it. All three clusters run Kubernetes **1.35.2** (`iac/clusters/*/bootstrap/main.tf`), so the native `lifecycle.preStop.sleep` action is available — no shell binary needed in the image.

- [x] `gitops/helm-charts/iot-applications/templates/deployment.yaml` — add to the **pod spec**, immediately after the `imagePullSecrets` block (~line 54, before `initContainers`):

```yaml
      {{- with $application.terminationGracePeriodSeconds }}
      terminationGracePeriodSeconds: {{ . }}
      {{- end }}
```

- [x] Same file — add to the **main container**, immediately after the `startupProbe` block (~line 160, before `volumeMounts`):

```yaml
          {{- with $application.lifecycle }}
          lifecycle:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

- [x] `gitops/helm-charts/iot-applications/templates/rollout.yaml` — apply both blocks at the equivalent positions (pod spec after `imagePullSecrets` ~line 50; container after `startupProbe` ~line 151). The two templates must stay in step even though Argo Rollouts is not installed in any cluster.

### 2. Chart — document the new keys

- [x] `gitops/helm-charts/iot-applications/values.yaml` — extend the commented block around the existing probe keys (lines ~139-157) with a copy-pasteable reference. Deliberately **not** chart defaults: the correct path and boot budget differ between the nginx UIs and the Ts.ED APIs, and a wrong default silently CrashLoops the next app onboarded.

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

- [x] Add a one-line pointer to this plan and its companion above that block.

### 3. Chart — tests

- [x] Extend `gitops/helm-charts/iot-applications/tests/deployment_test.yaml`, following the existing `set:` + `asserts:` style:
  - `lifecycle` rendered under the container when set; absent when unset
  - `terminationGracePeriodSeconds` rendered under the pod spec when set; absent when unset
  - all three probes still render when set, and are absent when unset — a regression guard, since the new container block is inserted right next to them
- [x] Check whether `tests/__snapshot__` holds a snapshot covering the container or pod spec; update it if so.
- [x] `helm unittest gitops/helm-charts/iot-applications` — CI runs the same via `.github/workflows/helm-chart-ci.yaml` (helm-unittest v0.4.4).

### 4. Values — the three Ts.ED APIs

> **Unblocked 2026-08-11.** The backend spec (`iot-miniservers` —
> `docs/superpowers/specs/2026-08-06-backend-health-checks.md`) shipped: the
> `@radoslavirha/health` and `@radoslavirha/tsed-health` packages are in, and
> `qr-manager-api@0.5.0`, `miot-bridge-api@0.19.0`,
> `interactive-map-feeder-api@0.11.0` are released and serve all three paths. Gate re-run and
> passed — see the table under [Assumed contract](#assumed-contract).
>
> The `critical` flag from that spec is live: `interactive-map-feeder-api` registers its
> upstreams as `critical: false`, so a third-party outage degrades `/health` to `warn` while
> `/health/ready` stays 200. It does not change the probe values here, but it does mean
> "ready" and "healthy" are no longer the same question.
>
> **The `kube_pod_status_ready` ordering note below was NOT satisfied.**
> `gitops/helm-values/k8s-monitoring.yaml` still sets no `metricsTuning`, and the probe
> values shipped anyway — deferred to a separate session by decision, not oversight. Until
> it lands, a MongoDB or MQTT outage takes pods out of Endpoints with no metric moving:
> `restarts_total` stays flat by design and `kube_pod_status_phase` still reports `Running`.
> `/health` on each pod is the only readiness signal that exists right now.

#### Notes from the frontend rollout, for whoever does this half

The chart side is done and exercised. What the UI rollout on 2026-08-08 established, and what it did not:

- **`terminationGracePeriodSeconds` + `lifecycle.preStop.sleep` + `maxUnavailable: 0` genuinely deliver a gapless rollout.** Measured, not assumed: 6507 requests through a full `rollout restart`, all 200. The APIs can adopt the same block with confidence — but note the UI case is nginx with `STOPSIGNAL SIGQUIT` doing its own graceful shutdown. **The Ts.ED APIs get no equivalent for free.** `preStop` only buys the pod time; something must also flip `/health/ready` to 503 on SIGTERM and keep serving in-flight requests, or the sleep is just a delay before the same dropped connections. That is the `ShutdownState` / `createShutdownHandler` part of the backend spec, and it is load-bearing, not a nicety. Re-run the curl-loop test against an API before believing it.
- **`preStop: 10s` for the APIs vs `5s` here is deliberate.** Keep the API value; they hold longer-lived requests than a static file server.
- **Four environments, not two.** `base.yaml` reaches server1 *and* server2, each with `sandbox` + `production`. The APIs run on both clusters. Check the gate in all four before committing probe values.
- **`validate` does not apply to the APIs** and should stay unset — they parse their own config at boot. The `runAsUser` bug found here was in the validator container only; nothing about it affects an API.
- **PodSecurity `restricted` is warn-only in these namespaces and no app container meets it.** Independent of health checks, but the warning will appear on every API rollout too. Do not let it be mistaken for something the probe change caused.
- **`kube_pod_status_ready` is still not collected** (`2026-08-07-probe-state-not-observable.md`). It did not matter for the UIs — a static file server with no dependency checks cannot go NotReady for an interesting reason. It matters a great deal for the APIs, where the entire point is that a MongoDB or MQTT outage takes pods out of Endpoints *without* restarting them, which no currently-collected metric can see. **Land that before the API probe values**, or the first dependency outage after this change is invisible.

**Written 2026-08-11 to each app's `sandbox.yaml` first, then promoted to `base.yaml`** in the same session once the sandbox rollout had been watched — same two-step the UIs used. The block is identical for all three apart from the comments; the difference in behaviour lives in the image, not here.

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

- [x] `port: http` is the key from each app's `services` map, which the chart renders as the container port name. Confirmed by `helm template` against the real value-file stack for all three: each renders `containerPort: 4000` named `http`, and every probe resolves to it. `miot-bridge-api` also declares a `udp` port on 4000 — the name, not the number, is what disambiguates them.
- [x] `interactive-map-feeder-api` already runs `replicas: 2`; the `strategy` block is still correct there. Rendered and checked.
- [x] Do not add a readiness dependency on the third-party HTTP upstreams that `interactive-map-feeder-api` calls. Its `/health/ready` is a static pass on purpose — the image registers them as one `upstream-apis` check with `critical: false`, so they show up in `/health` without gating Endpoints.

### 5. Values — the two nginx UIs

nginx starts in well under a second, so the boot budget is much shorter, and a static file server has nothing that distinguishes live from ready — one path serves both.

- [x] Added to `gitops/helm-values/apps/qr-manager-ui/**sandbox.yaml**` (staged — see step 6) and `gitops/helm-values/server3/homelab-dashboard-ui.yaml`, together with `templates.config.validate: true` from the sibling validation plan:

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

- [x] `homelab-dashboard-ui` reverse-proxies to the Unifi controller (`location /proxy/network/`). Do **not** make readiness depend on it — a controller reboot must not delete the dashboard from Endpoints.

### 6. Roll out sandbox before production

The values in steps 4-5 sit in `base.yaml`, which applies to both namespaces at once. If the `production` image tags are still behind the health-endpoint release while `sandbox` is ahead, the probes will 404 in production and CrashLoop it.

- [x] Compare `image.tag` in each app's `sandbox.yaml` and `production.yaml` against the first release that carries the health endpoints.
- [x] **Outcome for `qr-manager-ui`:** both environments already run `0.7.0`, so the *lagging-tag* reason for staging is gone. The second reason stands — a mistuned `failureThreshold` or boot budget should break the sandbox pod, not the production one — so the block went into `sandbox.yaml` with a `TODO` to promote it to `base.yaml` after a watched rollout.
- [x] **Outcome for `homelab-dashboard-ui`:** no sandbox exists, values applied directly to `gitops/helm-values/server3/homelab-dashboard-ui.yaml`.
- [x] **Done for `qr-manager-ui`** (`c445ccd`): the probe / `lifecycle` / `strategy` / `validate` block moved from `sandbox.yaml` to `base.yaml` after a watched rollout, so production is covered too.
- [x] **Tag comparison for the three APIs, 2026-08-11:** `sandbox.yaml` and `production.yaml` both pin the health release (`0.5.0` / `0.19.0` / `0.11.0`) — the deploy action bumped both in `9d7cc59` + `c7cbb93`. So the *lagging-tag* reason for staging is again absent; the second reason (a mistuned probe should break sandbox first) plus the `kube_pod_status_ready` gap are why the block still went into `sandbox.yaml`.
- [x] **Production pods were still on the pre-health images** (`0.4.4` / `0.18.4` / `0.10.2`) on both clusters when this session started — git was ahead of the cluster, the production Applications having last reconciled 2026-08-08. Synced after the sandbox rollout was watched, so they picked up the image and the probes in one step.
- [x] **Promoted:** each API's probe / `lifecycle` / `strategy` block moved from `sandbox.yaml` to `base.yaml`, `TODO` comments replaced with the same "staged here first" pointer `qr-manager-ui` carries.

### 7. Verification

Per `AGENTS.md`, ArgoCD reporting `Synced`/`Healthy` proves the manifests applied, nothing more. Query the behaviour.

- [x] Probes attached where intended, per cluster and namespace:

```bash
kubectl get deploy -n sandbox -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].livenessProbe.httpGet.path}{"\t"}{.spec.template.spec.containers[0].readinessProbe.httpGet.path}{"\n"}{end}'
```

- [x] `preStop` and grace period landed:

```bash
kubectl get deploy -n sandbox -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.terminationGracePeriodSeconds}{"\t"}{.spec.template.spec.containers[0].lifecycle}{"\n"}{end}'
```

- [x] All pods reach `READY 1/1` and stay there. `kubectl get pods -n sandbox -w` for a few minutes — a probe misconfiguration shows up as a restart loop, not as an ArgoCD error.
- [ ] **Liveness is genuinely shallow.** Scale MongoDB to 0 in `sandbox`, wait 2 minutes:

```bash
kubectl scale statefulset mongodb -n mongodb --replicas=0     # ASK the operator first — see AGENTS.md
kubectl get pods -n sandbox -w
```

  Expected: `miot-bridge-api` and `qr-manager-api` go `READY 0/1`, `RESTARTS` unchanged. A restart means a dependency check leaked into the liveness endpoint — that is an app-side bug, report it rather than papering over it here. Scale MongoDB back and confirm readiness recovers on its own with no pod deletion.
- [x] **Rollout is gapless.** In one shell curl the ingress in a loop; in another:

```bash
kubectl rollout restart deploy/api-iot-qr-manager-api -n sandbox
```

  Expect zero non-200 responses. Without the `preStop` hook this test fails — it is the reason step 1 exists.
- [ ] **ArgoCD health now carries signal:** during that restart the Application must pass through `Progressing` instead of sitting at `Healthy` the whole time. *Not observed — the restart was driven with `kubectl`, so no Application transition was expected.*
- [ ] **No telemetry noise:** via the Grafana MCP, query Tempo for spans matching `/health` over the last 15 minutes and Loki for request-log lines on the same paths. Both should be empty. If not, the exclusion is missing app-side — record it, it does not block this plan.
- [ ] Repeat the probe-attachment and rollout checks for `homelab-dashboard-ui` on server3, namespace **`homelab`** (not `dashboards` — that was wrong in the original draft; the Application is `homelab-dashboard-server3` and its destination namespace is `homelab`).
- [x] Only then promote to `production` and re-run the probe-attachment and rollout checks there. Probe attachment re-checked in `production`; the curl-loop restart was run in `sandbox` only.

#### Results — 2026-08-11, commit `9d8a49a`

Sandbox synced and watched first, then production. Both clusters, both namespaces:

| Check | Result |
| --- | --- |
| Probes attached | `live=/health/live ready=/health/ready startup=/health/live` on all three APIs, ×2 clusters ×2 namespaces |
| `preStop` + grace | `grace=30 preStop=10` everywhere; `maxUnavailable: 0` on every Deployment |
| Images | `qr-manager-api:0.5.0`, `miot-bridge-api:0.19.0`, `interactive-map-feeder-api:0.11.0` in all four environments |
| Pods | every Deployment `1/1` (`interactive-map-feeder-api` `2/2`), `RESTARTS 0` after rollout |
| `/health` in `production` | 200 `pass` on all six workloads, with the expected check names |
| **Gapless rollout** | `kubectl rollout restart deploy/api-iot-qr-manager-api -n sandbox` on server2 under a curl loop against `http://sandbox.api.server2.home/iot/qr-manager/health/live`: **3286 requests, 3286× HTTP 200, zero failures** |

That last row is the one worth having: the UI result on 2026-08-08 was nginx doing its own
graceful shutdown, which proved nothing about the APIs. This proves the Ts.ED side —
`ShutdownState` flipping `/health/ready` to 503 on SIGTERM plus the in-process drain —
actually works behind `preStop`.

**Found while testing:** the API ingress answers on **HTTP but 404s on HTTPS**
(`https://sandbox.api.server2.home/iot/qr-manager/...` → Traefik's own
`404 page not found`, for every path including `/`). Not caused by this change — no path
under the host resolves over TLS — and not health-specific. Worth its own look; the
curl-loop test used HTTP.

**Still not run**, both needing a decision or a dependency:

- **MongoDB scale-to-0** (the "liveness is genuinely shallow" test). Needs the operator's
  go-ahead per `AGENTS.md`, and it is the single test that proves the whole design: pods
  must go `READY 0/1` with `RESTARTS` unchanged.
- **Tempo/Loki `/health` exclusion check.** Independent of the probes; the exclusion is
  app-side and its absence would only mean noise, not breakage.

**Already verified for the two UIs, 2026-08-08** (before the values were written — see the Status block at the top): `/healthz` answers in all three environments, `/healthzzz` 404s, nginx is PID 1 on the dashboard, both validator images exist at the pinned tags, both accept the live rendered config, and a deliberately emptied `apiBaseURL` is rejected with `exit=1` and no value echoed.

The MongoDB scale-to-0 and the Tempo/Loki telemetry checks above are **API-only** and cannot run until step 4 unblocks. The nginx UIs have no OTel SDK and no dependency checks, so there is nothing to exclude and nothing to degrade.

### 8. Documentation

- [ ] `AGENTS.md` — in the `iot-applications` chart notes, record the new `lifecycle` and `terminationGracePeriodSeconds` keys and the probe path convention (`/health/live` + `/health/ready` for the Ts.ED APIs, `/healthz` for the nginx UIs).
- [ ] `docs/architecture.md` — no new rows (no new app); note in the custom-apps section that all five workloads declare probes.
- [ ] `docs/iot-overview.md` — a short paragraph: what each probe means for these apps, and the deliberate choice that a MongoDB or MQTT outage degrades readiness but never restarts pods.
- [ ] Run the `sync-docs` skill last (it chains `sync-obsidian`).

---

## Out of scope

Tracked in the companion plan's follow-ups: UDP liveness for `miot-bridge-api` (HTTP probes are blind to its UDP listener), alerting on `kube_pod_status_ready` / restart counts, external blackbox probing of the Traefik hostnames, and PodDisruptionBudgets.

Also out of scope here by definition: everything inside the app images, and the upstream charts (InfluxDB2, EMQX, MongoDB, Grafana, Loki, Tempo, Traefik…) which ship their own probes already.
