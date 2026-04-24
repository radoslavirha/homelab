# ArgoCD AppProjects — Follow-up Plan

> Follow-up to the Bootstrap App-of-Apps restructure (already landed). This plan covers only the AppProject CRDs that were deferred to avoid churn.

**Goal:** Add ArgoCD `AppProject` CRDs for UI grouping of Applications. No functional change to sync behavior — Bootstrap + sync waves already handle ordering.

**Context:** GitHub Issue [#2](https://github.com/radoslavirha/homelab/issues/2).

---

## What is already done (out of scope here)

- `Bootstrap.yaml` meta App-of-Apps created at `gitops/argocd-manifests/Bootstrap.yaml`.
- All 9 Root Apps moved to `gitops/argocd-manifests/roots/` (with `server3/` subdir).
- Root Apps annotated with `argocd.argoproj.io/sync-wave` (waves 1–4).
- Application CRD health check restored via Lua `resource.customizations` in `gitops/helm-values/server3/argocd.yaml`.
- Docs (`README.md`, `AGENTS.md`, `docs/architecture.md`, `docs/quickstart.md`, `gitops/README.md`) updated to the 2-apply bootstrap.

Current bootstrap: `kubectl apply -f ArgoCD.yaml && kubectl apply -f Bootstrap.yaml`.

All Applications and ApplicationSets currently sit in `spec.project: default`.

---

## What this plan adds

Six `AppProject` CRDs under `gitops/argocd-manifests/roots/projects/`. Each ApplicationSet / Application is reassigned to its matching project via `spec.project`.

Homelab has no multi-tenant RBAC — all projects use wildcard `sourceRepos` and `destinations`. Goal is purely UI grouping in the ArgoCD dashboard.

### Project layout

|Project|Apps assigned|
|-------|-------------|
|`infrastructure`|ESO, Traefik, ExternalDNS|
|`observability`|OTelGateway, Prometheus, Grafana, Loki, Tempo|
|`iot`|IotInfra, InfluxDB2, EMQX, Telegraf|
|`databases`|MongoDB|
|`dashboards`|Headlamp, Hubble, Longhorn, OpenBao|
|`apps`|AppsOTelCollector, MiotBridgeApiIot, InteractiveMapFeederApiIot|

Root Apps themselves stay on `project: default` — they are management-plane resources, not workloads.

### Sync-wave on AppProjects

Projects carry `argocd.argoproj.io/sync-wave: "0"` so they exist before any `Application` referencing them lands via Bootstrap (which starts at wave 1). Bootstrap picks them up automatically via `recurse: true`.

---

## Task 1 — Create AppProject CRDs

**New files:**

- `gitops/argocd-manifests/roots/projects/infrastructure.yaml`
- `gitops/argocd-manifests/roots/projects/observability.yaml`
- `gitops/argocd-manifests/roots/projects/iot.yaml`
- `gitops/argocd-manifests/roots/projects/databases.yaml`
- `gitops/argocd-manifests/roots/projects/dashboards.yaml`
- `gitops/argocd-manifests/roots/projects/apps.yaml`

Template (swap `name` + `description` per project):

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: infrastructure
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  description: Infrastructure apps — ESO, Traefik, ExternalDNS
  sourceRepos:
    - '*'
  destinations:
    - server: '*'
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```

---

## Task 2 — Assign `spec.project` to every ApplicationSet / Application

### ApplicationSets under `gitops/argocd-manifests/apps/`

|File|New `spec.project`|
|----|------------------|
|`apps/infra/ESO.yaml`|`infrastructure`|
|`apps/gateway/Traefik.yaml`|`infrastructure`|
|`apps/gateway/ExternalDNS.yaml`|`infrastructure`|
|`apps/observability/OTelGateway.yaml`|`observability`|
|`apps/iot/IotInfra.yaml`|`iot`|
|`apps/iot/InfluxDB2.yaml`|`iot`|
|`apps/iot/EMQX.yaml`|`iot`|
|`apps/iot/Telegraf.yaml`|`iot`|
|`apps/databases/MongoDB.yaml`|`databases`|
|`apps/dashboards/Headlamp.yaml`|`dashboards`|
|`apps/dashboards/Hubble.yaml`|`dashboards`|
|`apps/dashboards/Longhorn.yaml`|`dashboards`|
|`apps/apps/AppsOTelCollector.yaml`|`apps`|
|`apps/apps/MiotBridgeApiIot.yaml`|`apps`|
|`apps/apps/InteractiveMapFeederApiIot.yaml`|`apps`|

### Singleton Applications under `gitops/argocd-manifests/server3/apps/`

|File|New `spec.project`|
|----|------------------|
|`server3/apps/dashboards/OpenBao.yaml`|`dashboards`|
|`server3/apps/observability/Prometheus.yaml`|`observability`|
|`server3/apps/observability/Grafana.yaml`|`observability`|
|`server3/apps/observability/Loki.yaml`|`observability`|
|`server3/apps/observability/Tempo.yaml`|`observability`|

Root Apps under `gitops/argocd-manifests/roots/**/*.yaml` and `ArgoCD.yaml` + `Bootstrap.yaml` stay on `project: default`.

---

## Task 3 — Docs

Update to mention AppProjects:

- [AGENTS.md](../../../AGENTS.md) — directory layout already lists `roots/`; add `roots/projects/` row and a line about project grouping under "Adding a new ArgoCD app".
- [gitops/README.md](../../../gitops/README.md) — add a short "AppProjects" section after "App-of-apps pattern".

---

## Verification

1. **Projects exist before dependent Apps sync:**

   ```bash
   kubectl get appprojects -n argocd
   ```

   Should list `default` + 6 new projects.

2. **No orphaned Applications** (pointing at a non-existent project):

   ```bash
   for app in $(kubectl get app -n argocd -o name); do
     p=$(kubectl get $app -n argocd -o jsonpath='{.spec.project}')
     kubectl get appproject $p -n argocd >/dev/null 2>&1 || echo "MISSING project: $p for $app"
   done
   ```

3. **Dry-run** each project CRD:

   ```bash
   kubectl apply --dry-run=server -f gitops/argocd-manifests/roots/projects/
   ```

4. **UI check** — ArgoCD dashboard groups Applications by project.

---

## Rollout order (single PR)

1. Commit new `roots/projects/*.yaml` files (wave 0, exist immediately after push).
2. In the same commit, update `spec.project` on all 20 ApplicationSets / Applications.

Bootstrap picks up `roots/projects/*.yaml` via `recurse: true` and applies them at wave 0, ahead of any child App referencing them. Safe in a single PR.

## Notes

- If multi-tenant RBAC is ever added, tighten `sourceRepos` and `destinations` per project.
- Future: split `apps` project per environment (production / sandbox) if blast-radius isolation is needed.
