# ArgoCD Root Manifests Restructure Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the ArgoCD bootstrap from 9 manual `kubectl apply` calls to 2, enforce dependency ordering automatically via sync waves, and group applications in the ArgoCD UI using AppProject CRDs.

**Context:** GitHub Issue [#2](https://github.com/radoslavirha/homelab/issues/2) — "Argocd root manifests".

**Current state:** 9 Root Applications are applied manually in strict sequence. There is no automated ordering enforcement and no UI grouping. The required manual sequence is:
1. `ArgoCD.yaml` (self-management)
2. `RootInfra.yaml` (ESO must be up before Traefik needs the Unifi ExternalSecret)
3. `RootGateway.yaml` (Traefik + ExternalDNS)
4. `server3/RootDashboards.yaml` (OpenBao HTTPRoute — needed so server2 ESO can reach `vault.server3.home`)
5–9. `server3/RootObservability.yaml`, `RootObservability.yaml`, `RootIoT.yaml`, `RootDatabases.yaml`, `RootDashboards.yaml` (all depend on Traefik)

**Target state:** Apply only `ArgoCD.yaml` (once) and `Bootstrap.yaml` (once). `Bootstrap.yaml` is a meta App-of-Apps that discovers all Root Apps from `roots/` and enforces sync wave ordering automatically. AppProject CRDs provide UI grouping.

**Architecture:**

```
Manual applies (2 total):
  ArgoCD.yaml      → ArgoCD manages itself
  Bootstrap.yaml   → discovers roots/ (recurse: true) → manages all Root Apps

Bootstrap sync waves:
  wave 0  → AppProject CRDs (infrastructure, observability, iot, databases, dashboards)
  wave 1  → RootInfra          (ESO)
  wave 2  → RootGateway        (Traefik + ExternalDNS)
             server3/RootDashboards (OpenBao HTTPRoute)
  wave 3  → RootObservability, server3/RootObservability
             RootIoT, RootDatabases, RootDashboards
```

**Target directory structure:**

```
gitops/argocd-manifests/
├── ArgoCD.yaml                              ← unchanged (manual apply #1)
├── Bootstrap.yaml                           ← NEW (manual apply #2)
├── roots/
│   ├── projects/
│   │   ├── infrastructure.yaml              ← NEW AppProject (wave 0)
│   │   ├── observability.yaml               ← NEW AppProject (wave 0)
│   │   ├── iot.yaml                         ← NEW AppProject (wave 0)
│   │   ├── databases.yaml                   ← NEW AppProject (wave 0)
│   │   └── dashboards.yaml                  ← NEW AppProject (wave 0)
│   ├── RootInfra.yaml                       ← MOVED + wave 1 annotation
│   ├── RootGateway.yaml                     ← MOVED + wave 2 annotation
│   ├── RootObservability.yaml               ← MOVED + wave 3 annotation
│   ├── RootIoT.yaml                         ← MOVED + wave 3 annotation
│   ├── RootDatabases.yaml                   ← MOVED + wave 3 annotation
│   ├── RootDashboards.yaml                  ← MOVED + wave 3 annotation
│   └── server3/
│       ├── RootDashboards.yaml              ← MOVED + wave 2 annotation
│       └── RootObservability.yaml           ← MOVED + wave 3 annotation
├── apps/                                    ← unchanged (ApplicationSets)
└── server3/apps/                            ← unchanged (singleton Applications)
```

---

### Task 1: Create `Bootstrap.yaml`

**Files:**
- Create: `gitops/argocd-manifests/Bootstrap.yaml`

- [ ] **Step 1: Create the Bootstrap Application manifest**

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/radoslavirha/homelab.git
    targetRevision: HEAD
    path: gitops/argocd-manifests/roots
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

- [ ] **Step 2: Commit**

```bash
git add gitops/argocd-manifests/Bootstrap.yaml
git commit -m "feat(argocd): add Bootstrap meta App-of-Apps"
```

---

### Task 2: Create AppProject CRDs in `roots/projects/`

**Files:**
- Create: `gitops/argocd-manifests/roots/projects/infrastructure.yaml`
- Create: `gitops/argocd-manifests/roots/projects/observability.yaml`
- Create: `gitops/argocd-manifests/roots/projects/iot.yaml`
- Create: `gitops/argocd-manifests/roots/projects/databases.yaml`
- Create: `gitops/argocd-manifests/roots/projects/dashboards.yaml`

All AppProjects use wildcard `sourceRepos` and `destinations` (homelab — no multi-tenant RBAC needed). All carry `argocd.argoproj.io/sync-wave: "0"` so they exist before any Application references them.

- [ ] **Step 1: Create `roots/projects/infrastructure.yaml`**

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
```

- [ ] **Step 2: Create `roots/projects/observability.yaml`**

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: observability
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  description: Observability stack — OTelGateway, Prometheus, Grafana, Loki, Tempo
  sourceRepos:
    - '*'
  destinations:
    - server: '*'
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
```

- [ ] **Step 3: Create `roots/projects/iot.yaml`**

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: iot
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  description: IoT apps — InfluxDB2, EMQX, Telegraf
  sourceRepos:
    - '*'
  destinations:
    - server: '*'
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
```

- [ ] **Step 4: Create `roots/projects/databases.yaml`**

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: databases
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  description: Databases — MongoDB
  sourceRepos:
    - '*'
  destinations:
    - server: '*'
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
```

- [ ] **Step 5: Create `roots/projects/dashboards.yaml`**

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: dashboards
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  description: Dashboards — Headlamp, Hubble, Longhorn, OpenBao UI
  sourceRepos:
    - '*'
  destinations:
    - server: '*'
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
```

- [ ] **Step 6: Commit**

```bash
git add gitops/argocd-manifests/roots/projects/
git commit -m "feat(argocd): add AppProject CRDs for UI grouping"
```

---

### Task 3: Move Root Applications to `roots/` and add sync-wave annotations

**Files:**
- Move: `gitops/argocd-manifests/RootInfra.yaml` → `gitops/argocd-manifests/roots/RootInfra.yaml`
- Move: `gitops/argocd-manifests/RootGateway.yaml` → `gitops/argocd-manifests/roots/RootGateway.yaml`
- Move: `gitops/argocd-manifests/RootObservability.yaml` → `gitops/argocd-manifests/roots/RootObservability.yaml`
- Move: `gitops/argocd-manifests/RootIoT.yaml` → `gitops/argocd-manifests/roots/RootIoT.yaml`
- Move: `gitops/argocd-manifests/RootDatabases.yaml` → `gitops/argocd-manifests/roots/RootDatabases.yaml`
- Move: `gitops/argocd-manifests/RootDashboards.yaml` → `gitops/argocd-manifests/roots/RootDashboards.yaml`
- Move: `gitops/argocd-manifests/server3/RootDashboards.yaml` → `gitops/argocd-manifests/roots/server3/RootDashboards.yaml`
- Move: `gitops/argocd-manifests/server3/RootObservability.yaml` → `gitops/argocd-manifests/roots/server3/RootObservability.yaml`

Note: `gitops/argocd-manifests/server3/apps/` is **not** moved — the singleton Applications remain at that path. Only the Root Applications that point at `server3/apps/` are moved.

Sync wave to add per file (added under `metadata.annotations`):

| File (after move) | Sync wave | Reason |
|---|---|---|
| `roots/RootInfra.yaml` | `"1"` | ESO first — Traefik needs Unifi ExternalSecret |
| `roots/RootGateway.yaml` | `"2"` | Traefik before any HTTPRoute |
| `roots/server3/RootDashboards.yaml` | `"2"` | OpenBao HTTPRoute before server2 ESO reaches `vault.server3.home` |
| `roots/RootObservability.yaml` | `"3"` | Needs Traefik HTTPRoute + Prometheus/Loki/Tempo endpoints |
| `roots/server3/RootObservability.yaml` | `"3"` | Needs Traefik HTTPRoute + ESO (grafana-admin ExternalSecret) |
| `roots/RootIoT.yaml` | `"3"` | Needs Traefik HTTPRoute |
| `roots/RootDatabases.yaml` | `"3"` | Needs Traefik TCP route |
| `roots/RootDashboards.yaml` | `"3"` | Needs Traefik HTTPRoute |

Example annotation block to add to each moved file (adjust wave number per table above):

```yaml
metadata:
  name: root-infra          # existing
  namespace: argocd         # existing
  annotations:
    argocd.argoproj.io/sync-wave: "1"   # ADD THIS
```

- [ ] **Step 1: Move files**

```bash
mkdir -p gitops/argocd-manifests/roots/server3
mv gitops/argocd-manifests/RootInfra.yaml         gitops/argocd-manifests/roots/RootInfra.yaml
mv gitops/argocd-manifests/RootGateway.yaml        gitops/argocd-manifests/roots/RootGateway.yaml
mv gitops/argocd-manifests/RootObservability.yaml  gitops/argocd-manifests/roots/RootObservability.yaml
mv gitops/argocd-manifests/RootIoT.yaml            gitops/argocd-manifests/roots/RootIoT.yaml
mv gitops/argocd-manifests/RootDatabases.yaml      gitops/argocd-manifests/roots/RootDatabases.yaml
mv gitops/argocd-manifests/RootDashboards.yaml     gitops/argocd-manifests/roots/RootDashboards.yaml
mv gitops/argocd-manifests/server3/RootDashboards.yaml      gitops/argocd-manifests/roots/server3/RootDashboards.yaml
mv gitops/argocd-manifests/server3/RootObservability.yaml   gitops/argocd-manifests/roots/server3/RootObservability.yaml
```

- [ ] **Step 2: Add `argocd.argoproj.io/sync-wave` annotation to each moved file**

Edit each of the 8 moved files and add the sync-wave annotation per the table above.

- [ ] **Step 3: Verify no broken `source.path` references**

The moved Root Apps point at:
- `gitops/argocd-manifests/apps/infra` (unchanged path — OK)
- `gitops/argocd-manifests/apps/gateway` (unchanged — OK)
- `gitops/argocd-manifests/apps/observability` (unchanged — OK)
- `gitops/argocd-manifests/apps/iot` (unchanged — OK)
- `gitops/argocd-manifests/apps/databases` (unchanged — OK)
- `gitops/argocd-manifests/apps/dashboards` (unchanged — OK)
- `gitops/argocd-manifests/server3/apps/dashboards` (unchanged — OK)
- `gitops/argocd-manifests/server3/apps/observability` (unchanged — OK)

No `source.path` values need updating — only the file locations change.

- [ ] **Step 4: Commit**

```bash
git add gitops/argocd-manifests/roots/ gitops/argocd-manifests/server3/
git commit -m "feat(argocd): move Root Apps to roots/ and add sync-wave annotations"
```

---

### Task 4: Assign projects to ApplicationSets and singleton Applications

**Files (update `spec.project` in each):**

| File | Current `project` | New `project` |
|---|---|---|
| `apps/infra/ESO.yaml` | `default` | `infrastructure` |
| `apps/gateway/Traefik.yaml` | `default` | `infrastructure` |
| `apps/gateway/ExternalDNS.yaml` | `default` | `infrastructure` |
| `apps/observability/OTelGateway.yaml` | `default` | `observability` |
| `apps/iot/InfluxDB2.yaml` | `default` | `iot` |
| `apps/iot/EMQX.yaml` | `default` | `iot` |
| `apps/databases/MongoDB.yaml` | `default` | `databases` |
| `apps/dashboards/Headlamp.yaml` | `default` | `dashboards` |
| `apps/dashboards/Hubble.yaml` | `default` | `dashboards` |
| `apps/dashboards/Longhorn.yaml` | `default` | `dashboards` |
| `server3/apps/dashboards/OpenBao.yaml` | `default` | `dashboards` |
| `server3/apps/observability/Prometheus.yaml` | `default` | `observability` |
| `server3/apps/observability/Grafana.yaml` | `default` | `observability` |
| `server3/apps/observability/Loki.yaml` | `default` | `observability` |
| `server3/apps/observability/Tempo.yaml` | `default` | `observability` |

- [ ] **Step 1: Update project field in all 15 files listed above**

In each file, change:
```yaml
spec:
  project: default
```
to the appropriate project name from the table.

- [ ] **Step 2: Commit**

```bash
git add gitops/argocd-manifests/apps/ gitops/argocd-manifests/server3/apps/
git commit -m "feat(argocd): assign ApplicationSets and Apps to ArgoCD projects"
```

---

### Task 5: Update documentation

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/architecture.md`
- Modify: `gitops/README.md`

- [ ] **Step 1: Update `AGENTS.md`**

Update the "Adding a new ArgoCD app" section to mention assigning `spec.project` to the correct AppProject.

Update the directory layout section to show the new `roots/` and `Bootstrap.yaml` structure.

Update the manual apply sequence note:

```markdown
Root Application CRDs live in `gitops/argocd-manifests/`. Apply once manually:
1. `ArgoCD.yaml` — ArgoCD self-management
2. `Bootstrap.yaml` — meta App-of-Apps; discovers `roots/` recursively and manages all Root Apps with sync-wave ordering (wave 0: Projects → wave 1: ESO → wave 2: Gateway + OpenBao HTTPRoute → wave 3: everything else)
```

Remove the paragraph listing 9 files to apply manually.

- [ ] **Step 2: Update `docs/architecture.md`**

Update the ArgoCD bootstrap section to reflect 2-apply sequence and sync wave ordering. Check if there is a technology stack row for ArgoCD itself and update the description/notes if needed.

- [ ] **Step 3: Update `gitops/README.md`**

Update any section that lists the manual apply sequence to reflect the new 2-step process.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md docs/architecture.md gitops/README.md
git commit -m "docs: update ArgoCD bootstrap sequence to 2-step Bootstrap pattern"
```

---

## Notes / Decisions

- `ArgoCD.yaml` stays outside `Bootstrap` — chicken-and-egg: ArgoCD must exist before it can process `Bootstrap.yaml`.
- Root Apps themselves remain in `project: default` — they are management plane resources, not workloads.
- `server3/apps/` singleton Applications and the ApplicationSets under `apps/` are not moved — only the Root App pointers are moved to `roots/`.
- AppProject `sourceRepos` and `destinations` use wildcards — homelab has no multi-tenant RBAC requirements.
- Telegraf (IoT, server1+server2) will be added as a separate task once server1 is registered in ArgoCD. No structural changes are needed beyond adding `apps/iot/Telegraf.yaml` and the corresponding helm values / k8s-manifests.
- "My apps" can follow the same Bootstrap pattern with a separate `BootstrapApps.yaml` — out of scope for this plan.
