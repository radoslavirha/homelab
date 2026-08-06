# Automatic Workload Restarts on ConfigMap/Secret Change — Stakater Reloader

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** When an ESO-synced Secret changes, the workloads that baked its value into a running process restart automatically. Today nothing restarts: apps consume ESO secrets via `envFrom.secretRef` (`gitops/helm-charts/iot-applications/templates/deployment.yaml`), which Kubernetes never re-injects into a running container, and the Jinja2 init container renders secrets into a config file **once at pod start**. A rotation in OpenBao silently leaves every pod on the old value until someone deletes it by hand.

**Chosen tool:** [Stakater Reloader](https://github.com/stakater/Reloader) — chart `2.2.14`, appVersion `v1.4.19`, repo `https://stakater.github.io/stakater-charts`. Verified: every values key used below exists in 2.2.14 and is rendered into a real flag by `templates/deployment.yaml`.

**Architecture:** One Reloader release per cluster (server1 · server2 · server3), namespace `reloader`, deployed by a new ApplicationSet in the existing **infra** stage (sync-wave 1, next to ESO). Reloader is cluster-local — it must run in every cluster whose workloads should restart; the server3 ArgoCD instance only ships the manifests.

**Mode:** opt-in (`reloader.stakater.com/auto: "true"` per workload), the upstream default and the common pattern — no blanket `autoReloadAll`. Six workloads need it for **secrets**; two more get annotated because the chart's `checksum/config` is being removed in favour of a single restart mechanism. Analysis below.

---

## Which workloads actually need Reloader

Restart only helps when a value is **read once and cached in the process**. Sorted by verdict.

### Needs Reloader — a secret can change behind their back

| Workload | Cluster / ns | What it consumes | Why a restart is the only fix |
| --- | --- | --- | --- |
| `miot-bridge-api` | server1 · server2, `production` + `sandbox` | `miot-bridge-api-mqtt-credentials`, `miot-bridge-api-mongodb-credentials` via `envFrom.secretRef` + Jinja2 init env | env vars are frozen at container start; `production.json` is rendered once |
| `qr-manager-api` | server1 · server2, `production` + `sandbox` | `qr-manager-api-mongodb-credentials` via `envFrom.secretRef` | same |
| `homelab-dashboard-ui` **(frontend)** | server3, `dashboards` | `homelab-dashboard-ui-unifi-credentials` → `SECRET_UNIFI_API_KEY` **rendered into `/usr/share/nginx/html/config.json`** by the Jinja2 init container | nginx serves a static file containing the key. Rotate the Unifi key and the browser keeps getting the dead one forever |
| `telegraf` | server2, `telegraf` | `telegraf-influxdb2-credentials`, `telegraf-mqtt-credentials` via `env.valueFrom.secretKeyRef` | Telegraf reads env at boot only. **Chart has no workload-annotation key — see gap below** |
| `grafana` | server3, `monitoring` | `grafana-admin` (`admin.existingSecret`) + `server1/server2-influxdb2-grafana` via `extraSecretMounts`, referenced as `$__file{/etc/secrets/.../token}` in the datasource ConfigMaps | kubelet does refresh the mounted file, but Grafana reads it during datasource **provisioning**, i.e. at startup. Sidecar reload only fires on ConfigMap change, not on secret-file change |
| `external-dns` | all clusters, `external-dns` | `unifi-credentials` via `env.valueFrom.secretKeyRef` | env frozen at start; a stale Unifi key silently breaks DNS record updates |

### No secret rotation exposure

| Workload | Why not |
| --- | --- |
| `qr-manager-ui`, `interactive-map-feeder-api` (frontends) | No `secretRefs` at all — nothing rotates behind their back. They still get the annotation, because step 4b removes the chart's `checksum/config` and Reloader becomes the only thing that restarts them when their Jinja2 ConfigMap changes via git |
| `traefik` | No secrets in values; dynamic config comes from CRDs, watched live |
| `prometheus` | Config hot-reload via `/-/reload` + the chart's configmap-reload sidecar; no secrets |
| `loki`, `tempo` | No secrets; config changes arrive via git and the charts hash their own config into the pod template |
| `k8s-monitoring` / Alloy | OTLP bearer auth was dropped (commit `dd3dd49`) — no secret is referenced any more. The chart hashes its own Alloy config |
| `external-secrets` (ESO) | Authenticates to OpenBao with a Kubernetes ServiceAccount token (`ClusterSecretStore` → `auth.kubernetes`); no static secret. Reads secret material fresh on every sync |
| `argocd` | Watches `argocd-cm` / `argocd-secret` through the API and reloads itself |
| `headlamp`, Hubble UI, Longhorn UI, OpenBao HTTPRoute | No secrets consumed by the workload |

### Deliberately excluded — restart does not apply the new credential

| Workload | Why excluded |
| --- | --- |
| `influxdb2` (server1 · server2, `iot`) | `adminUser.existingSecret` is consumed by the **init** path only. The token/password live in the TSDB after first boot; restarting with a changed Secret changes nothing and can interrupt writes |
| `emqx` (server2, `iot`) | `envFromSecret: emqx-credentials` bootstraps the dashboard user into mnesia on first boot only |
| `mongodb` (server2, `mongodb`) | Root credentials are applied at initdb time. Restarting with a Secret that no longer matches the on-disk user is a way to lock yourself out |
| PostSync provisioner Jobs (`gitops/helm-charts/provisioner`) | Jobs are one-shot; a "restart" is meaningless. Covered by `ignoreJobs` / `ignoreCronJobs` |

Rotating any of those three datastores stays a two-sided manual operation — see `docs/superpowers/plans/2026-04-22-credential-rotation.md`.

### Known gap — telegraf

The influxdata `telegraf` chart exposes `podAnnotations`, `service.annotations` and `serviceAccount.annotations` — **no Deployment-level annotations key**. Reloader's `auto` annotation must sit on the workload, not the pod template, so telegraf cannot be opted in through values.

Options, in order of preference:

1. **Accept it for now** — document `kubectl rollout restart deploy/telegraf -n telegraf` in `docs/secrets.md` next to the telegraf rotation steps. Rotations here are rare and already manual.
2. Open an upstream PR adding `deploymentAnnotations` to the chart (external-dns and traefik both have it; it is an uncontroversial addition).
3. Convert the Telegraf Application to a kustomize-with-helm source to patch the annotation in — restructures the Application for one annotation. Not worth it.

Step 4 below takes option 1.

---

## Key decisions

### 1. Opt-in annotations, not `autoReloadAll`

`reloader.autoReloadAll: true` would cover everything with no per-chart work, including telegraf. Rejected: the analysis above shows only **6 of ~20** workloads benefit, three datastores must be actively excluded, and the blanket switch also reaches the Terraform-managed charts (Cilium, Longhorn, OpenBao, ArgoCD) that this repo does not otherwise touch from GitOps. Opt-in is also the upstream default and the pattern every chart's docs assume.

Cost of opt-in, all of it accounted for in the steps: `iot-applications` renders only `labels` on `Deployment`/`Rollout` metadata, so the chart needs an `annotations` field (~10 lines + tests). `grafana` (`annotations:`) and `external-dns` (`deploymentAnnotations:`) already have the key.

### 2. `reloadStrategy: annotations` + ArgoCD `ignoreDifferences`

Kubernetes only rolls pods when the **pod template** changes; a Secret changing is invisible to it. So Reloader deliberately scribbles in the pod template to force a rollout. The strategy picks *where it scribbles*:

- `env-vars` (what the chart's `default` resolves to) — injects `STAKATER_<SECRET_NAME>_SECRET=<hash>` into **every container** in the pod.
- `annotations` — adds one pod-template annotation, `reloader.stakater.com/last-reloaded-from: {"type":"SECRET","name":"…","hash":"…"}`.

Same end result. The difference only matters because ArgoCD diffs live-vs-git and both look like drift, and every Application here runs `selfHeal: true` — left alone ArgoCD reverts the patch and triggers a second, pointless rollout. Suppressing one annotation key takes a single jq path per workload kind; suppressing an env var means matching it inside every container array. Hence `annotations`.

### 3. One restart mechanism, not two — `checksum/config` goes

The chart's `checksum/config` pod annotation (sha256 of `$application.templates`) and Reloader both fire on the *same* ConfigMap. Keeping both means two rollouts per git config change: ArgoCD applies the new ConfigMap plus the new checksum (rollout 1), then Reloader observes the ConfigMap update and patches its own annotation (rollout 2).

Reloader wins because it is a superset: it catches git-driven ConfigMap changes *and* the out-of-band ESO secret changes the checksum can never see. Removing the checksum means the two secretless UI apps must be annotated too — Reloader becomes their only restart path.

Trade-off accepted: restarts now depend on the Reloader Deployment being alive, where before they were a pure function of the rendered manifest.

### 4. Argo Rollouts — not applicable

The Argo Rollouts controller is not installed in any cluster (the only trace in the repo is `iac/clusters/server3/apps/terraform.tfstate`), and no values file sets `rollout.enabled`. `reloader.isArgoRollouts` stays `false`. Revisit if Rollouts is ever adopted.

---

## Steps

### 1. Shared Helm values

- [ ] Create `gitops/helm-values/reloader.yaml`:

```yaml
# Stakater Reloader — shared Helm values
# Upstream values.yaml: https://github.com/stakater/Reloader/blob/master/deployments/kubernetes/chart/reloader/values.yaml
# Restarts workloads whose pods cached a Secret value that ESO has since rotated.
# Opt-in: annotate the workload with reloader.stakater.com/auto: "true".

reloader:
  # Opt-in mode (chart default). See the workload analysis in
  # docs/superpowers/plans/2026-08-05-stakater-reloader.md — only 6 workloads
  # benefit, and influxdb2/emqx/mongodb must NOT be restarted on secret change.
  autoReloadAll: false

  # Writes spec.template.metadata.annotations."reloader.stakater.com/last-reloaded-from"
  # instead of injecting a dummy env var into every container. Paired with the
  # ignoreDifferences entries in gitops/helm-values/server3/argocd.yaml so
  # ArgoCD selfHeal does not revert the patch and cause a second rollout.
  reloadStrategy: annotations

  # Argo Rollouts controller is not installed in any cluster.
  isArgoRollouts: false

  # PostSync provisioner Jobs (gitops/helm-charts/provisioner) are one-shot.
  ignoreJobs: true
  ignoreCronJobs: true

  watchGlobally: true
  logFormat: json

  deployment:
    replicas: 1
    resources:
      requests:
        cpu: 10m
        memory: 128Mi
      limits:
        cpu: 100m
        memory: 512Mi
```

- [ ] Create `gitops/helm-values/server1/reloader.yaml`, `gitops/helm-values/server2/reloader.yaml`, `gitops/helm-values/server3/reloader.yaml` — comment-only placeholders following the `external-secrets.yaml` precedent:

```yaml
# Stakater Reloader — <cluster> cluster overrides
# Shared base values: gitops/helm-values/reloader.yaml
# No cluster-specific overrides at this time.
```

> Both files must exist: the ApplicationSet lists shared + cluster `valueFiles`, and ArgoCD fails the render on a missing path.

### 2. ApplicationSet — infra stage

- [ ] Create `gitops/argocd-manifests/apps/infra/Reloader.yaml`, copying the shape of `apps/infra/ESO.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: reloader
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
      name: reloader-{{cluster}}
    spec:
      project: default
      sources:
        - repoURL: https://stakater.github.io/stakater-charts
          chart: reloader
          targetRevision: 2.2.14
          helm:
            releaseName: reloader
            valueFiles:
              - $values/gitops/helm-values/reloader.yaml
              - $values/gitops/helm-values/{{cluster}}/reloader.yaml
        - repoURL: https://github.com/radoslavirha/homelab
          targetRevision: HEAD
          ref: values
      destination:
        server: '{{clusterServer}}'
        namespace: reloader
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
        automated:
          selfHeal: true
          prune: true
```

- [ ] No Root Application change needed — `roots/RootInfra.yaml` discovers `apps/infra/` with `directory.recurse: true`.
- [ ] Infra is sync-wave 1 (with ESO). Reloader has no CRDs and no dependency on ESO, so wave 1 is correct and it is up before any secret can rotate.

### 3. Suppress Reloader's patch in ArgoCD diffing

- [ ] Add to `configs.cm` in `gitops/helm-values/server3/argocd.yaml`, next to the existing `resource.customizations.health.argoproj.io_Application` entry:

```yaml
    # Stakater Reloader patches the pod template annotation below to trigger a
    # rolling update when a referenced ConfigMap/Secret changes. Without this,
    # selfHeal reverts the patch and causes a second, pointless rollout.
    resource.customizations.ignoreDifferences.apps_Deployment: |
      jqPathExpressions:
        - '.spec.template.metadata.annotations."reloader.stakater.com/last-reloaded-from"'
    resource.customizations.ignoreDifferences.apps_StatefulSet: |
      jqPathExpressions:
        - '.spec.template.metadata.annotations."reloader.stakater.com/last-reloaded-from"'
    resource.customizations.ignoreDifferences.apps_DaemonSet: |
      jqPathExpressions:
        - '.spec.template.metadata.annotations."reloader.stakater.com/last-reloaded-from"'
```

> **Coordination:** another agent is working in this repo. `gitops/helm-values/server3/argocd.yaml` is a pre-existing file — re-read it immediately before editing and merge rather than overwrite.

- [ ] Verify `argocd-cm` picked it up: `kubectl get cm argocd-cm -n argocd -o yaml | grep -A3 ignoreDifferences`

### 4. Annotate the workloads that need it

#### 4a. `iot-applications` chart — add workload annotations support

- [ ] `gitops/helm-charts/iot-applications/templates/deployment.yaml` — add annotations to the **Deployment** metadata (currently `labels` only):

```yaml
metadata:
  name: {{ include "iot-applications.identifier" $ctx }}
  labels: {{ include "iot-applications.meta.labels" $ctx | nindent 4 }}
  {{- with $application.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
```

- [ ] Apply the identical block to `templates/rollout.yaml` (Rollout metadata) so the two stay in step even though Rollouts is unused.
- [ ] Document the new `annotations` key in `gitops/helm-charts/iot-applications/values.yaml`, in the commented `apps:` block near `podAnnotations` (line ~121). State the difference: `annotations` = workload metadata (what Reloader reads), `podAnnotations` = pod template.
- [ ] Extend `gitops/helm-charts/iot-applications/tests/deployment_test.yaml`: annotations rendered when set, absent when unset. Update `tests/__snapshot__` if a snapshot assertion covers Deployment metadata.
- [ ] Run `helm unittest gitops/helm-charts/iot-applications` locally — CI runs the same via `.github/workflows/helm-chart-ci.yaml` (helm-unittest v0.4.4).

#### 4b. `iot-applications` chart — remove `checksum/config`

Reloader and the checksum annotation both restart on the *same* ConfigMap. Keeping both means **two rollouts per config change**: ArgoCD applies the new ConfigMap plus the new checksum (rollout 1), then Reloader observes the ConfigMap update and patches `last-reloaded-from` (rollout 2). Pick one — Reloader, since it also covers the out-of-band ESO case the checksum can never see.

- [ ] Remove the `checksum/config` line from `templates/deployment.yaml` (line ~40) and `templates/rollout.yaml` (line ~37).
- [ ] Simplify the surrounding conditional — the annotations block now renders on `$application.annotations`/`podAnnotations` alone, not on `$application.templates | len`.
- [ ] Update `values.yaml` comments at lines ~94 (“Pods automatically restart when content changes (checksum annotation)”) and ~122 (“checksum/config is added automatically when templates are defined”) — replace with the Reloader annotation requirement.
- [ ] Update `Readme.md` line ~50 (same claim).
- [ ] Update `tests/deployment_test.yaml`: drop the two `checksum/config` assertions (lines ~121 and ~148) and rename the “should NOT render annotations block when no templates and no podAnnotations” case, whose premise changes.

> **Consequence to accept:** config changes previously restarted pods with no moving parts. Afterwards they depend on Reloader running — if it is down, ArgoCD updates the ConfigMap but pods keep serving the file rendered at their last start (the Jinja2 init container runs only at pod start). Reloader sits in wave 1; consider a pod-availability alert.

#### 4c. Annotate the apps

Every app that mounts a Jinja2 ConfigMap now needs the annotation, not only the ones with secrets — with `checksum/config` gone, Reloader is the sole restart path for config changes.

- [ ] `gitops/helm-values/apps/miot-bridge-api/base.yaml` — add under the app key (secrets **and** config):

```yaml
    annotations:
      reloader.stakater.com/auto: "true"
```

- [ ] Same in `gitops/helm-values/apps/qr-manager-api/base.yaml` (secrets + config)
- [ ] Same in `gitops/helm-values/server3/homelab-dashboard-ui.yaml` (secret baked into the served `config.json`)
- [ ] Same in `gitops/helm-values/apps/qr-manager-ui/base.yaml` (config only — no secrets)
- [ ] Same in `gitops/helm-values/apps/interactive-map-feeder-api/base.yaml` (config only — no secrets)

#### 4d. Grafana

- [ ] `gitops/helm-values/grafana.yaml` — the chart's top-level `annotations` maps to Deployment metadata:

```yaml
# Restart Grafana when grafana-admin or the influxdb2 token secrets rotate.
# Datasource tokens are read via $__file{} during provisioning, i.e. at startup.
annotations:
  reloader.stakater.com/auto: "true"
```

#### 4e. ExternalDNS

- [ ] `gitops/helm-values/external-dns.yaml`:

```yaml
# Restart when unifi-credentials rotates — the API key is read from env at boot.
deploymentAnnotations:
  reloader.stakater.com/auto: "true"
```

#### 4f. Telegraf — document the gap

- [ ] No values change possible (chart has no Deployment-level annotations key). Record the manual step in `docs/secrets.md`:
  `kubectl rollout restart deploy/telegraf -n telegraf`
- [ ] Add a `TODO` comment at the top of `gitops/helm-values/telegraf.yaml` pointing at this plan section so the gap is discoverable.

### 5. Verify ESO actually delivers changes

Reloader can only react to a Secret that already changed. ExternalSecrets here use `refreshInterval: 1h`.

- [ ] Confirm the expected end-to-end latency after an OpenBao write is **up to 1h** (ESO poll) + seconds (Reloader). Document it; do not lower `refreshInterval` globally.
- [ ] Note the manual fast path: `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite`

### 6. Verification

- [ ] `kubectl get pods -n reloader` on each cluster — one running pod (deployment is named `reloader-reloader`: release + chart name).
- [ ] `kubectl logs -n reloader deploy/reloader-reloader` — confirm it starts in opt-in mode and watches globally.
- [ ] Confirm the annotation actually landed on the workload, not the pod template:
  `kubectl get deploy miot-bridge-api -n sandbox -o jsonpath='{.metadata.annotations}'`
- [ ] End-to-end on server2 / `sandbox` (lowest blast radius):
  1. note the current pod name and age
  2. change a value in the Secret — an annotation-only edit does nothing, Reloader hashes `data`. Either `kubectl edit secret miot-bridge-api-mqtt-credentials -n sandbox` or rotate in OpenBao and force-sync the ExternalSecret
  3. new ReplicaSet + pod appears; `kubectl get deploy … -o jsonpath='{.spec.template.metadata.annotations}'` shows `reloader.stakater.com/last-reloaded-from`
  4. wait one ArgoCD reconcile (~3 min) — Application must stay **Synced/Healthy**. If it flaps OutOfSync, the jq path in step 3 is wrong
  5. let ESO restore the real value if the Secret was hand-edited
- [ ] Regression test for the removed checksum: change a `templates.config.content` value for `qr-manager-ui` in git, sync, and confirm the pod restarts. This path used to be covered by `checksum/config`; if it does not restart, the annotation is missing or Reloader is not watching that namespace.
- [ ] Repeat the `homelab-dashboard-ui` case specifically: rotate the Unifi key, confirm the new pod's `/usr/share/nginx/html/config.json` contains the new value (`kubectl exec … -- cat …`). This is the frontend case where a stale value is invisible from the outside.

### 7. Documentation

- [ ] `docs/architecture.md` — add a Reloader row: Purpose (restart workloads on ConfigMap/Secret change), Clusters (server1 · server2 · server3), Managed by (ArgoCD — infra stage), Artifact Hub link, Local values (`shared · server1 · server2 · server3`), Upstream `values.yaml` link.
- [ ] `AGENTS.md` — add `reloader.yaml` to the `gitops/helm-values/` listing and `Reloader (AppSet)` to the `infra/` stage line; mention the new `annotations` key in the `iot-applications` chart section if one exists.
- [ ] `docs/secrets.md` — rotation section: which workloads now restart automatically, which are deliberately excluded (influxdb2 · emqx · mongodb) and why, the telegraf manual restart, and the force-sync command.
- [ ] Run the `sync-docs` skill last (it chains `sync-obsidian`).

---

## Optional — Reloader metrics

- [ ] Reloader exposes a reload counter on `:9090`. `serviceMonitor` is deprecated upstream in favour of `podMonitor`. Only worth enabling if `k8s-monitoring` on that cluster discovers PodMonitors; otherwise skip — a reload is already visible as a pod restart in existing dashboards.

## Alternatives considered

| Option | Verdict |
| --- | --- |
| **Stakater Reloader** | **Chosen.** Handles Deployments/StatefulSets/DaemonSets, ConfigMaps + Secrets, opt-in per workload, works with any chart that can set workload annotations. |
| `autoReloadAll: true` | Rejected as the default mode — see decision 1. Kept as the escape hatch if per-chart annotations become tedious, or if more charts turn out to lack an annotations key like telegraf. |
| Helm `checksum/config` annotations | Present in `iot-applications` (sha256 of `$application.templates`) but it hashes **values**, not the live Secret — ESO-driven changes never touch git, so it never moves. Covers the git-change case only, and running it alongside Reloader on the same ConfigMap causes a double rollout. **Removed in step 4b.** |
| ESO restart hooks | ESO has no built-in workload-restart feature; its own docs point at Reloader. |
| `kubectl rollout restart` in a PostSync hook | Fires on ArgoCD sync, not on secret change. A rotation without a git commit still goes unnoticed. |
| Mount secrets as files instead of `envFrom` | Kubelet does refresh mounted secret volumes (~60s), but every consumer here reads config at boot (Jinja2 init container, Grafana provisioning, Telegraf env), so the process still needs a restart. Bigger change, does not remove the need for Reloader. |
