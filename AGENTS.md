# Agent Guidelines — homelab

Kubernetes homelab: three Talos Linux clusters, provisioned with Terraform (`iac/`) and run by ArgoCD
from git (`gitops/`). Cluster overview: [README.md](README.md). Decisions, technology stack table and
roadmap: [docs/architecture.md](docs/architecture.md).

## Contents

- Agentic tooling — where skills and rules live, and how to write them
- Clusters — what runs where
- Operating rules — git, not commands; what needs asking
- Commands — run freely / intended writes / ask first
- Access — kubeconfig, talosconfig, ArgoCD
- Backups — what exists and what it does not cover
- Task index — which skill, rule or doc covers a task
- Adding a third-party app · Adding a cluster
- Terminology — `stage` and `apps` each mean three things

## Agentic tooling

All skills, instructions and agents live in `.apm/` and nowhere else:

```
.apm/
  skills/<name>/SKILL.md                on-demand procedures; references/, scripts/, evals/ beside it
  instructions/<name>.instructions.md   path-scoped rules; `applyTo:` globs say when they load
  agents/<name>.agent.md                (none yet)
```

- `apm install` deploys them: skills to `.claude/skills/`, instructions to `.claude/rules/` with
  `applyTo` converted to `paths:`, so a rule loads only when a matching file is read. **Never edit the
  deployed copies in `.claude/` or `.github/`** — the next install overwrites them. `.github/workflows/`
  is ordinary CI and fine to edit. Do not modify `apm.yml`.
- An edit to `.apm/` is not live until `apm install` runs, and running it is the operator's call.
  `apm audit` reports drift between `.apm/` and the deployed copies.
- Writing or changing a skill: follow
  [Anthropic's skill best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices).
  In this repo that means: SKILL.md under 500 lines; references one level deep from SKILL.md; a
  `## Contents` list at the top of any reference file over 100 lines; prerequisites (CLIs, kubeconfig)
  stated up front; a copyable checklist for multi-step procedures; a validate → fix → repeat loop for
  anything that can break; `evals/evals.json` with at least three scenarios.

## Clusters

| Cluster | Runs |
|---------|------|
| server1 | Every datastore (InfluxDB2, EMQX, MongoDB, the shared CloudNativePG Postgres). Every IoT custom app, in `production` and `sandbox` namespaces under a default-deny NetworkPolicy; knowledge-base-api in `production` only. Mealie, Open WebUI |
| server2 | Ollama — the LLM engine since 2026-09-20. No datastores, no custom apps |
| server3 | ArgoCD (manages all three clusters), OpenBao, Authentik, the LGTM stack (Prometheus, Grafana, Loki, Tempo), homelab-dashboard-ui |

## Operating rules

1. **Change the clusters through git, not through commands.** ArgoCD syncs every app with `selfHeal`
   and `prune`, so an imperative change is reverted within minutes. Edit the manifest, commit, sync. An
   agent that fixes something with `kubectl` has not fixed it. The one exception is the
   `network-policies-*` Applications, manual-sync on purpose — see the `network-egress` skill.
2. **Reading is unrestricted.** `kubectl get/describe/logs`, the Application CRs, and Prometheus,
   Loki or Tempo through the Grafana MCP.
3. **Restarts and a single sync are routine.** `kubectl rollout restart`, `delete pod`, one ArgoCD sync:
   a controller recreates the pod and ArgoCD converges on committed state. **Sync once, then wait.**
   Re-triggering tears down in-flight PostSync provisioner Jobs and can wedge the Application.
4. **Anything holding data: ask first, every time.** PersistentVolumeClaims, PersistentVolumes,
   Longhorn volumes, namespaces, StatefulSets and CRDs are not covered by "git will put it back".
   Prometheus, Loki, Tempo, MongoDB and InfluxDB2 data lives in Longhorn and exists nowhere else.
5. **A denial is a decision.** Permission enforcement lives in the Claude Code harness, configured
   locally by the operator. Do not route around a denial, and never edit the permission configuration.
6. **Green does not mean working.** `Synced`/`Healthy` with Running pods proves the manifests applied,
   not that telemetry, traffic or data flows. Two k8s-monitoring bugs once sat green for hours while
   collecting nothing. Verify by querying the data — `count by (cluster) (kube_pod_status_phase)`, the
   Loki label `k8s_cluster_name` — or run the `probe-traffic` skill.
7. **`Synced` can be stale.** A values-only commit hits a stale multi-source cache and reads `Synced`
   while serving the old values, and a change reaching only a PostSync hook Job never shows
   `OutOfSync` at all. Compare the app's `status.sync.revision(s)` with `git rev-parse origin/main`;
   if they differ, hard refresh, then sync once.
8. **One hard refresh is not contained.** It invalidates the repo cache for the whole `repoURL`, so
   every app tracking `HEAD` with unsynced commits behind it reconciles at once — on 2026-09-06 a
   refresh meant for one app synced nine. Before refreshing, `git log` from the revision the apps report.

## Commands

**Run freely** (read-only):

```bash
terraform plan | validate | output
kubectl get | describe | logs
talosctl health | logs <service> | get disks
kubectl -n argocd get applications            # ArgoCD state lives in the Application CRs
git status | diff | log
```

**Intended writes** — no need to ask:

```bash
terraform apply -auto-approve                 # version bumps and config changes
kubectl rollout restart deploy/<name>
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd patch application <name> --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'            # sync — once
kubectl -n argocd patch application <name> --type merge -p '{"operation": null}'   # clear a stuck sync
```

**Ask before running** (destructive or irreversible):

```bash
terraform destroy
talosctl upgrade | reset | wipe disk
kubectl delete <resource>
rm -rf, or any deletion of credentials
```

## Access

The bootstrap stage writes credentials to `iac/clusters/<cluster>/credentials/` (gitignored). There is
no `~/.kube/config`: each kubeconfig holds exactly one context, `admin@<cluster>`.

```bash
export KUBECONFIG=iac/clusters/<cluster>/credentials/kubeconfig     # one cluster
export TALOSCONFIG=iac/clusters/<cluster>/credentials/talosconfig

# Commands written with --context admin@serverN need all three merged:
export KUBECONFIG=iac/clusters/server1/credentials/kubeconfig:iac/clusters/server2/credentials/kubeconfig:iac/clusters/server3/credentials/kubeconfig
```

ArgoCD runs on server3. Drive it with `kubectl --context admin@server3 -n argocd` against the
Application CRs, or with the ArgoCD MCP tools. The local `argocd` CLI is logged in to a retired
hostname and fails; `argocd --core` fails from outside the cluster. If the CLI is ever needed, log it in
to `argocd.server3.homelab.irha.cz` first.

## Backups

**Take a dump before anything that cannot be rolled back.** Longhorn has no downgrade path, Kubernetes
has no downgrade path, and there is no volume-level restore.

```bash
~/homelab-backups/dump-all.sh     # lives OUTSIDE this repo; credentials come from ./.env
```

It dumps etcd on all three clusters, the Authentik Postgres, MongoDB, InfluxDB and an OpenBao raft
snapshot, writes `SHA256SUMS`, uploads offsite and verifies the remote copy. **It is run by hand —
nothing schedules it**, so check the date of the newest directory in `~/homelab-backups/` before
trusting it. Automating it is open work; the script is a stopgap.

- **Not a Longhorn backup.** `backupTarget` is `""`, there are no RecurringJobs or Snapshots, and no
  CSI snapshotter. These are logical dumps — a rebuild path, not high availability. MinIO was dropped
  as a backup destination; do not re-propose it.
- **Not complete.** Prometheus, Loki, Tempo, Grafana and EMQX are excluded on purpose: reconstructible
  telemetry, provisioned from git, and broker runtime state. Mealie's and Open WebUI's Postgres are not
  dumped yet. Per-cluster table: [docs/architecture.md](docs/architecture.md).

## Task index

| Task | Go to |
|------|-------|
| Change what app pods may reach; a call times out in-cluster but works locally | skill `network-egress` |
| Prove that traffic, telemetry or reachability actually works | skill `probe-traffic` |
| Bump a chart, image, Terraform component or Talos; act on a Renovate PR | skill `upgrade-components` |
| Add, change or remove an Authentik application, role, client, device or proxy | skill `authentik-blueprints` |
| Update docs after any change | skill `sync-docs` |
| Why something is the way it is: past decisions, specs, design history, cross-repo contracts | skill `knowledge-base` (private knowledge base). Check it before changing anything non-obvious or re-proposing a design |
| Onboard an app from `radoslavirha/homelab-apps` | the `onboard-to-homelab` skill **in the homelab-apps repo**; it opens the PR here. Seed the OpenBao secrets listed in its TODO before the first sync |
| Secrets inventory and seeding | [docs/secrets.md](docs/secrets.md) |
| Bootstrap order, Terraform stages, module variables | [docs/iac.md](docs/iac.md) |
| Identity model, token claims, Headlamp OIDC | [docs/identity.md](docs/identity.md) |
| Observability stack, Grafana break-glass | [docs/observability.md](docs/observability.md) |

Path-scoped rules load on their own when you read files under `iac/`, `gitops/argocd-manifests/`,
`gitops/k8s-manifests/`, `gitops/helm-values/`, `gitops/helm-charts/app/` or
`gitops/helm-charts/authentik-blueprints/`. They carry the gotchas for those files.

## Adding a third-party app

```
- [ ] gitops/argocd-manifests/apps/<ArgoCD stage>/<Name>.yaml — copy an existing ApplicationSet
- [ ] gitops/helm-values/<name>.yaml (shared) and gitops/helm-values/<cluster>/<name>.yaml (overrides)
- [ ] gitops/k8s-manifests/<cluster>/<name>/ for raw manifests, if any
- [ ] a row in the technology stack table of docs/architecture.md (sync-docs skill has the columns)
- [ ] if it lands in production/sandbox on server1: network-egress skill
```

## Adding a cluster

```
- [ ] copy iac/clusters/server2/ (bootstrap + platform only) and fill in IPs, disk selectors, schematic ID
- [ ] set Cilium `devices:` to the real network interface
- [ ] terraform apply -auto-approve in bootstrap, then platform
- [ ] register it in ArgoCD: `argocd cluster add <context> --name <cluster>` (log the CLI in first — see Access)
- [ ] add a {cluster, clusterServer} element to each ApplicationSet that should target it, and commit
- [ ] sync-docs skill
```

## Terminology

Two words are overloaded here. Qualify them every time.

| Say | Means | Lives in |
|-----|-------|----------|
| Terraform stage | a root module per cluster: `bootstrap`, `platform`, `vault`, `apps`, `vault-config` | `iac/clusters/<cluster>/<stage>/` |
| ArgoCD stage | an App-of-Apps: `infra`, `gateway`, `observability`, `iot`, `databases`, `dashboards`, `apps`, `household`, `network-policies`, plus server3-only `dashboards`, `identity`, `observability` | `gitops/argocd-manifests/apps/<stage>/`, `.../server3/apps/<stage>/` |
| environment | `production` or `sandbox`, the custom-app namespaces on server1 | `values-<env>.yaml`, `network-policies/<env>/` |

`apps` is all three at once: the Terraform `apps` stage installs ArgoCD on server3, the ArgoCD `apps`
stage holds the custom apps on server1, and `homelab-apps` is the repo those apps come from.
