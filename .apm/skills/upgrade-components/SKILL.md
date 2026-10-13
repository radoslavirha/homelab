---
name: upgrade-components
description: "Upgrade a pinned version in this repo and confirm the new version actually runs: an ArgoCD-managed Helm chart, a household app image, a Terraform-managed component (Cilium, Longhorn, Gateway API CRDs, ArgoCD, OpenBao), Talos or Kubernetes. Use when bumping a version, acting on a Renovate PR or Dependency Dashboard item, or when a merged bump does not seem to have deployed."
argument-hint: "What to upgrade, e.g. 'loki chart to 18.13.0' or 'Renovate PR for cilium'"
---

# upgrade-components

A merged version bump is not a deployment. Where the pin lives decides what deploys it, and for some
components nothing does until a human acts. This skill finds the pin, proves the new version is safe
against **this repo's** values, deploys it the right way, and loops until the cluster runs it.

## Prerequisites

- CLIs: `git`, `helm`, `yq`, `kubectl`; `terraform` for `iac/`; `talosctl` for Talos.
- `KUBECONFIG` with all three clusters merged — the commands use `--context admin@<cluster>`
  (AGENTS.md § Access).
- A fresh dump before anything irreversible (AGENTS.md § Backups): Talos, Kubernetes, Longhorn, and
  anything that can move MongoDB across a release boundary.

## Where each version lives

| Component | Pin | Deployed by |
|-----------|-----|-------------|
| Helm chart (ArgoCD) | `targetRevision` in `gitops/argocd-manifests/apps/<ArgoCD stage>/<Name>.yaml` or `.../server3/apps/<ArgoCD stage>/<Name>.yaml` | ArgoCD |
| Household app (Mealie, Open WebUI, Ollama) | image tag in the Deployment under `gitops/k8s-manifests/<cluster>/<app>/` — no chart | ArgoCD |
| Provisioner image | `gitops/helm-charts/provisioner/values.yaml` → `image.digest` (a chart value, not Terraform) | ArgoCD |
| Talos Linux | `iac/clusters/<cluster>/bootstrap/main.tf` → `talos_version` | **nothing** — `talosctl upgrade` |
| Kubernetes | `iac/clusters/<cluster>/bootstrap/main.tf` → `kubernetes_version` | `terraform apply`, then verify |
| Cilium · Longhorn · Gateway API CRDs | `iac/clusters/<cluster>/platform/main.tf` → `cilium_version` · `longhorn_version` · `gateway_api_version` | `terraform apply` |
| ArgoCD | `iac/clusters/server3/apps/main.tf` → `argocd_chart_version` | `terraform apply` |
| OpenBao | `iac/clusters/server3/vault/main.tf` → `openbao_version` | `terraform apply` |
| Terraform providers | `iac/modules/<module>/versions.tf`; `clusters/server3/apps/main.tf` duplicates the helm pin — change both | `terraform init -upgrade` |
| `ArgoCD.yaml` | `gitops/argocd-manifests/ArgoCD.yaml` | **nothing** — `kubectl -n argocd apply -f` by hand |

**Renovate** (Mend app) watches every pin and reports to a Dependency Dashboard issue.
`dependencyDashboardApproval` is on repo-wide, so it opens nothing until a human ticks it; `automerge`
is off everywhere and must stay off. A new version variable needs a `# renovate:` annotation directly
above it or Renovate never sees it. Config: `renovate.json5`, validated by
`.github/workflows/renovate-validate.yaml`.

## Procedure

Copy this checklist into your response and tick it off:

```
Upgrade progress:
- [ ] 1. Pin located, deploy path known (table above)
- [ ] 2. Release notes OLD → NEW read for breaking changes
- [ ] 3. Upstream values.yaml diffed OLD → NEW against our override keys
- [ ] 4. OLD and NEW rendered with OUR values and diffed — nothing destructive
- [ ] 5. Image pin confirmed (chart pins the binary?)
- [ ] 6. Dump taken, if anything in this upgrade is irreversible
- [ ] 7. Pin changed (and its duplicate); diff shown to the operator
- [ ] 8. Deployed the way this pin deploys
- [ ] 9. Verified on the cluster: running version == NEW
- [ ] 10. sync-docs run, if a pin moved or a variable was added
```

### 1–4. Prove it is safe against this repo's values

Read the chart's source from the manifest — most are multi-source, with the chart in one source and
`$values` in another. Works for an ApplicationSet and a plain Application alike:

```bash
yq -o=csv '(.spec.template.spec.sources // .spec.sources)[] | select(.chart) | [.repoURL, .chart, .targetRevision]' \
  gitops/argocd-manifests/apps/<stage>/<Name>.yaml
# → https://traefik.github.io/charts,traefik,41.5.0
```

Upstream defaults, OLD against NEW — then check every key that changed against our override files:

```bash
helm show values <chart> --repo <repoURL> --version <OLD> > /tmp/upgrade-old-values.yaml
helm show values <chart> --repo <repoURL> --version <NEW> > /tmp/upgrade-new-values.yaml
diff -u /tmp/upgrade-old-values.yaml /tmp/upgrade-new-values.yaml
```

Then render both with **our** values and diff the output. This is what catches a renamed StatefulSet
orphaning a PVC, a dropped Service port, or a changed immutable selector:

```bash
for v in <OLD> <NEW>; do
  helm template <release> <chart> --repo <repoURL> --version "$v" \
    -f gitops/helm-values/<chart>.yaml -f gitops/helm-values/<cluster>/<chart>.yaml > "/tmp/upgrade-$v.yaml"
done
diff -u /tmp/upgrade-<OLD>.yaml /tmp/upgrade-<NEW>.yaml
```

(For an OCI chart use `oci://<registry>/<chart>` in place of `<chart> --repo <repoURL>`.)

**If the render diff renames or recreates a StatefulSet, PVC or CRD: stop and ask the operator.** That
is data loss, not an upgrade. If an override key no longer exists upstream, fix the values file, then
re-render and re-diff until the only differences are the ones you expect.

### 5. Does the chart pin the image?

Usually yes — the chart version moves the binary too. **`mongodb` is the exception**, and the only
Bitnami chart here: its image is `bitnami/mongodb:latest` in every chart version, so `targetRevision`
pins the YAML and says nothing about which `mongod` runs. Bitnami froze its versioned tags in Aug 2025;
a digest pin is the only option and is **deliberately not used**. MongoDB therefore moves on the next
*fresh* pull — a node rebuild or Talos upgrade — and that upgrades the data files irreversibly. Before
any node-level work, compare `mongod --version` with what `latest` resolves to now. Check any chart:

```bash
helm show values <chart> --repo <repoURL> --version <NEW> | sed -n '/^image:/,/^[a-z]/p'
```

### 8. Deploy the way this pin deploys

- **ArgoCD pin:** commit and push. Periodic reconciliation runs (measured working 2026-09-13), so most
  changes land within ~3 minutes. Two exceptions never show as `OutOfSync`: a values-only change (stale
  multi-source cache) and a change that only reaches a PostSync hook Job. For those, hard refresh, then
  **one** explicit sync — and remember a hard refresh reconciles every app with unsynced commits.
- **Terraform pin:** `terraform plan` first. It must touch only the resource you changed; a planned
  replacement of a Talos machine config or a `helm_release` is a cluster outage — stop and investigate.
  Then `terraform apply` in that cluster's stage. Across clusters, go **server2 → server1 → server3**,
  verifying between each: server2 is the platform canary (it no longer runs datastores, so a clean
  server2 proves the platform layer only); server3 goes last because breaking it blinds you.
- **Talos:** the variable only feeds `machine.install.image`, so `terraform apply` installs nothing.
  Ask the operator, take a dump, then per node:
  `talosctl upgrade --preserve --nodes <ip> --image factory.talos.dev/metal-installer/<schematic>:<version>`.
  A reboot of server3 reseals OpenBao — the operator unseals it by hand. Never bump
  `talos_secrets_contract` to do this.

### 9. Verify — loop until the cluster runs NEW

```bash
# ArgoCD: has the app taken the commit?
kubectl --context admin@server3 -n argocd get application <app> \
  -o jsonpath='{.status.sync.revision}{.status.sync.revisions}{"\n"}'
git rev-parse origin/main

# What actually runs
kubectl --context admin@<cluster> -n <ns> get pods -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u

# Terraform-managed
terraform plan                       # must be clean after apply, or state and reality disagree
talosctl --nodes <ip> version        # Talos
kubectl --context admin@<cluster> version
```

For a hook-only change, check `status.operationState.syncResult` for `hookPhase: Succeeded`.

If the running version is not NEW: find which step did not happen (revision not taken → hard refresh +
one sync; plan not clean → re-plan; Talos → was `talosctl upgrade` run?), fix that one thing, and
verify again. **Never loop syncs** — re-triggering tears down in-flight PostSync Jobs. Report the
running version you observed, not the pin you changed.

Terraform state has silently stopped describing reality here before: a Gateway API pin sat at one
version while all three clusters ran a newer one installed underneath it. A clean `terraform plan` plus
the live version is the only evidence a pin is real.
