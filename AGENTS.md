# Agent Guidelines — homelab

Kubernetes homelab: three Talos Linux clusters managed with Terraform (IaC) and ArgoCD (GitOps).
See [README.md](README.md) for cluster overview. See [docs/architecture.md](docs/architecture.md) for decisions and roadmap.

All agentic tools (skill, instruction, agents,..) must be added to `.apm` folder. Never update/add skills/instructions/agents `.github`/`.claude` (GitHub actions and related files allowed). Example Structure:
```
repository/
+-- apm.yml // do not modify
+-- .apm/
|   +-- skills/
|   |   +-- example-skill/
|   |       +-- SKILL.md
|   +-- agents/
|   |   +-- example.agent.md
|   +-- instructions/
```

## Repository layout

```
.github/
  workflows/
    provisioner-image.yaml  builds + pushes ghcr.io/radoslavirha/homelab-provisioner on Dockerfile change
provisioner/
  Dockerfile                fat image: curl, jq, influx CLI, bao CLI, mongosh (debian:bookworm-slim base)
iac/
  modules/
    bootstrap/    Talos cluster provisioning (reusable module)
    platform/     Cilium, Longhorn, Gateway API CRDs (reusable module)
    vault/      OpenBao (server3 only)
    apps/         ArgoCD install + self-management bootstrap (reusable module, server3 only)
    vault-config/ OpenBao's own configuration via the vault provider: auth methods, policies,
                  identity groups (server3 only). Today: OIDC login via Authentik. Runs AFTER
                  GitOps bootstrap, because the OIDC client secret exists only once Authentik is up
  clusters/
    helm-values/  Shared Cilium + Longhorn values (all clusters)
    server1/      bootstrap/ platform/ helm-values/
    server2/      bootstrap/ platform/ helm-values/
    server3/      bootstrap/ platform/ vault/ apps/ vault-config/ helm-values/
gitops/
  helm-charts/
    authentik-blueprints/   renders the Authentik configuration graph (applications, OAuth2 providers,
                            role groups, policy bindings) from the matrix in
                            helm-values/server3/authentik-blueprints.yaml. Roles are a LADDER:
                            `{ name: admin, inherits: editor }` becomes Authentik group parentage, and
                            membership flows UPWARD, so admin is the CHILD of editor and an admin-only
                            member gets all three roles in the claim. `kind` says what an entry is:
                            api (default, a human's browser logs in), client (a human drives it and it
                            calls other APIs -- Postman), device (a machine: confidential,
                            client_credentials, blueprint-declared service account).
                            Both non-api kinds carry `accesses` -- the APIs their token's aud names,
                            resolved within ONE environment. A client's roles come from the human's
                            groups; a device's access must name the role. See docs/identity.md.
    provisioner/            reusable PostSync provisioner Jobs chart (InfluxDB2, EMQX, MongoDB)
    iot-applications/       reusable chart for custom apps (Deployment/Rollout, Services, HTTPRoute,
                            Jinja2 config ConfigMap). Per-app `annotations` land on the WORKLOAD
                            metadata — set reloader.stakater.com/auto there; there is no
                            checksum/config, Reloader is the only restart mechanism.
                            `podAnnotations` land on the POD template — anything Alloy reads
                            (logs.grafana.com/*, resource.opentelemetry.io/*) belongs there, NOT
                            in `annotations`, where it fails silently. The chart auto-injects
                            resource.opentelemetry.io/service.name and .version (from image.tag)
                            onto every pod; a podAnnotations entry overrides either.
                            Health: `livenessProbe`/`readinessProbe`/`startupProbe` +
                            `lifecycle` (preStop.sleep) + `terminationGracePeriodSeconds` are
                            opt-in per app, never chart defaults. Paths by app type —
                            /health/live + /health/ready (Ts.ED APIs), /healthz (nginx UIs).
                            `templates.<name>.validate: true` generates an initContainer that
                            runs the app's own schema against the RENDERED config, image
                            derived as <image.repository>-config-validator:<image.tag>. Use it
                            for apps that cannot validate their own config (the nginx UIs);
                            the APIs fail their own boot and leave it unset
  helm-values/
    external-dns.yaml       shared: Unifi webhook provider, sources (gateway-httproute, traefik-proxy, crd), policy
    external-secrets.yaml   shared: installCRDs: true
    reloader.yaml           shared: Stakater Reloader, opt-in mode, reloadStrategy=annotations
    headlamp.yaml           shared: httpRoute + clusterRoleBinding
    traefik.yaml            shared: hostNetwork, Gateway API provider, listeners, bare-metal service
    emqx.yaml               shared: replica count, persistence, dashboard envFromSecret
    influxdb2.yaml          shared: org=homelab, existingSecret, Longhorn persistence 25Gi
    mongodb.yaml            shared: root credentials existingSecret, auth enabled
    telegraf.yaml           shared: InfluxDB2 + MQTT outputs, env secretKeyRefs
    prometheus.yaml         shared: TSDB only, remote-write receiver, Longhorn 20Gi, 30d retention
    grafana.yaml            shared: existingSecret grafana-admin, sidecar datasources+dashboards, Longhorn 5Gi
    loki.yaml               shared: Monolithic, filesystem storage, Longhorn 20Gi.
                            Ingest is the native OTLP endpoint (/otlp/v1/logs); index labels
                            come from Loki's default_resource_attributes_as_index_labels
    tempo.yaml              shared: local backend, OTLP receivers, metrics generator, Longhorn 20Gi
    k8s-monitoring.yaml     shared: Alloy collector map, feature toggles, telemetryServices,
                            OTLP receiver (no destinations). podLogsViaLoki.extraLogProcessingStages
                            lifts level/trace_id/span_id out of JSON log lines into structured
                            metadata — BOTH stage.json and stage.structured_metadata must live
                            there; the chart renders its own structuredMetadata: key earlier
    apps/
      common/               values.yaml only — VAR_PROTOCOL, VAR_MQTT_URL, VAR_MONGODB_URL. Per-cluster/per-stage
                            VARs (VAR_CLUSTER, VAR_PUBLIC_DOMAIN, VAR_SUBDOMAIN) are helm.parameters in the apps AppSets
      miot-bridge-api/  base.yaml, production.yaml, sandbox.yaml
      interactive-map-feeder-api/ base.yaml, production.yaml, sandbox.yaml
      qr-manager-api/   base.yaml, production.yaml, sandbox.yaml
      qr-manager-ui/    base.yaml, production.yaml, sandbox.yaml
    server1/              the only cluster running datastores and custom apps
      provisioner/          influxdb2.yaml, emqx.yaml, mongodb.yaml — provisioner chart values per datastore
      cert-manager.yaml     cluster-specific overrides
      emqx.yaml             server1 EMQX overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides
      headlamp.yaml         hostname: headlamp.server1.homelab.irha.cz
      influxdb2.yaml        server1 Longhorn storageClass overrides
      mongodb.yaml          server1 overrides
      k8s-monitoring.yaml   server1 cluster name + OTLP destination to server3
      reloader.yaml         cluster-specific overrides
      telegraf.yaml         server1 overrides (currently empty)
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip,
                            ports: 1883/8883/27017 + UDP 4000-4001 for the IoT estate
    server2/              platform only since 2026-09-13 — no datastores, no custom apps
      cert-manager.yaml     cluster-specific overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides
      headlamp.yaml         hostname: headlamp.server2.homelab.irha.cz
      k8s-monitoring.yaml   server2 cluster name + OTLP destination to server3
      reloader.yaml         cluster-specific overrides
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip.
                            Deliberately NO ports: block — see the comment in the file
    server3/
      argocd.yaml           ArgoCD helm overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides (currently empty)
      headlamp.yaml         hostname: headlamp.server3.homelab.irha.cz
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip, OTLP tracing endpoint
      prometheus.yaml       server3 overrides (currently empty)
      grafana.yaml          server3 overrides: extraSecretMounts for influxdb2-grafana secret
      k8s-monitoring.yaml   server3 self-contained: cluster name + local LGTM destinations.
                            Logs destination is type: otlp -> Loki's NATIVE OTLP endpoint
                            (:3100/otlp), NOT type: loki — that renders the deprecated
                            otelcol.exporter.loki, which always JSON-envelopes the line and
                            never emits structured metadata. Needs clusterLabels: [] plus
                            guarded OTTL, or it relabels every cluster's logs as server3
  argocd-manifests/
    ArgoCD.yaml             ArgoCD self-management (manual apply #1)
    Bootstrap.yaml          Meta App-of-Apps (manual apply #2) — discovers roots/, orders via sync waves
    roots/
      RootInfra.yaml          sync-wave: "1" — App-of-Apps → apps/infra/
      RootGateway.yaml        sync-wave: "2" — App-of-Apps → apps/gateway/
      RootObservability.yaml  sync-wave: "3" — App-of-Apps → apps/observability/
      RootIoT.yaml            sync-wave: "3" — App-of-Apps → apps/iot/
      RootDatabases.yaml      sync-wave: "3" — App-of-Apps → apps/databases/
      RootDashboards.yaml     sync-wave: "3" — App-of-Apps → apps/dashboards/
      RootApps.yaml           sync-wave: "4" — App-of-Apps → apps/apps/ (custom apps)
      RootNetworkPolicies.yaml sync-wave: "5" — App-of-Apps → apps/network-policies/
      server3/
        RootDashboards.yaml    sync-wave: "2" — App-of-Apps → server3/apps/dashboards/ (OpenBao HTTPRoute, homelab-dashboard-ui)
        RootIdentity.yaml      sync-wave: "3" — App-of-Apps → server3/apps/identity/ (Authentik + blueprints)
        RootObservability.yaml sync-wave: "3" — App-of-Apps → server3/apps/observability/ (LGTM stack)
    apps/
      infra/       ESO (AppSet, list generator), Reloader (AppSet, list generator), CertManager (AppSet, sync-wave: 2)
      gateway/     Traefik (AppSet), ExternalDNS (AppSet)
      observability/ K8sMonitoring (AppSet)
      iot/         InfluxDB2 (AppSet), EMQX (AppSet), Telegraf (AppSet), IotInfra (AppSet, sync-wave: -1)
      databases/   MongoDB (AppSet)
      dashboards/  Headlamp (AppSet), Hubble (AppSet), Longhorn (AppSet)
      apps/        MiotBridgeApi (AppSet), InteractiveMapFeederApi (AppSet), QrManagerApi (AppSet), QrManagerUi (AppSet)
      network-policies/ NetworkPolicies (AppSet, cluster × env) — MANUAL sync, deliberately
    server3/
      apps/
        dashboards/ OpenBao.yaml   App: vault.server3.homelab.irha.cz HTTPRoute
                    HomeLab.yaml   App: homelab-dashboard-ui (iot-applications chart, ns homelab)
        identity/   Authentik.yaml App: Authentik + authentik-blueprints chart
        observability/ Prometheus.yaml, Grafana.yaml, Loki.yaml, Tempo.yaml
  k8s-manifests/
    server1/
      cilium/              HTTPRoute: hubble.server1.homelab.irha.cz → hubble-dashboard:80
      cert-manager/        ExternalSecret (cloudflare-api-token), ClusterIssuer letsencrypt-staging + letsencrypt-prod (ACME DNS-01 via Cloudflare)
      external-secrets/    ClusterSecretStore → remote server3 OpenBao at vault.server3.homelab.irha.cz
      iot/         ExternalSecret.provisioner-token.yaml (openbao-provision-token; sync-wave -1 via IotInfra)
      influxdb2/   ExternalSecret.yaml, HTTPRoute.yaml
      emqx/        ExternalSecret.yaml, HTTPRoute.yaml, IngressRouteTCP.yaml (1883 plaintext + 8883 TLS)
      telegraf/    ExternalSecret.telegraf.influxdb2.yaml, ExternalSecret.telegraf.mqtt.yaml
      external-dns/ ExternalSecret (unifi-credentials), DNSEndpoint server1-anchor (server1.homelab.irha.cz A record)
      longhorn/    HTTPRoute: longhorn.server1.homelab.irha.cz → longhorn-frontend:80
      mongodb/     ExternalSecret, IngressRouteTCP (27017, TLS-only), ExternalSecret.provisioner-token.yaml
      miot-bridge-api/ production/ and sandbox/ — ExternalSecret.mqtt.yaml, ExternalSecret.mongodb.yaml
      qr-manager-api/ production/ and sandbox/ — ExternalSecret.mongodb.yaml, HTTPRoute.qr.yaml, Middleware.addprefix-qr.yaml
      network-policies/ production/ and sandbox/ — default-deny + the egress allow-list (manual-sync)
      k8s-monitoring/ ExternalSecret.otel-auth-token.yaml (shared OTLP bearer token pulled from secret/otel-gateway/auth-token)
      traefik/     Certificate.server1-tls.yaml → Secret server1-tls for the websecure listener
    server2/              platform only since 2026-09-13
      cilium/              HTTPRoute: hubble.server2.homelab.irha.cz → hubble-dashboard:80
      cert-manager/        ExternalSecret (cloudflare-api-token), ClusterIssuer letsencrypt-staging + letsencrypt-prod (ACME DNS-01 via Cloudflare)
      external-secrets/    ClusterSecretStore → remote server3 OpenBao at vault.server3.homelab.irha.cz
      external-dns/ ExternalSecret (unifi-credentials), DNSEndpoint server2-anchor (server2.homelab.irha.cz A record)
      longhorn/    HTTPRoute: longhorn.server2.homelab.irha.cz → longhorn-frontend:80
      k8s-monitoring/ ExternalSecret.otel-auth-token.yaml (shared OTLP bearer token pulled from secret/otel-gateway/auth-token)
      traefik/     Certificate.server2-tls.yaml → Secret server2-tls for the websecure listener
    server3/
      cilium/              HTTPRoute: hubble.server3.homelab.irha.cz → hubble-dashboard:80
      cert-manager/        ExternalSecret (cloudflare-api-token), ClusterIssuer letsencrypt-staging + letsencrypt-prod (ACME DNS-01 via Cloudflare)
      external-dns/        ExternalSecret (unifi-credentials), DNSEndpoint server3-anchor (server3.homelab.irha.cz A record)
      external-secrets/    ClusterSecretStore → local OpenBao
      longhorn/            HTTPRoute: longhorn.server3.homelab.irha.cz → longhorn-frontend:80
      openbao/             HTTPRoute: vault.server3.homelab.irha.cz → openbao:8200
      grafana/             ExternalSecret (grafana-admin), ExternalSecret (influxdb2-grafana), datasource ConfigMaps (prometheus/loki/tempo/influxdb2), dashboard ConfigMaps (traefik-opentelemetry, platform, loxone), HTTPRoute: grafana.irha.cz
      k8s-monitoring/      HTTPRoute: otel.server3.homelab.irha.cz → alloy-receiver:4318, IngressRouteTCP (otel gRPC :4317, plaintext)
      traefik/             Certificate.server3-tls.yaml → Secret server3-tls for the websecure listener
docs/             Architecture decisions, IaC guide, secrets guide, observability guide
```

## Module + cluster instance pattern

Modules in `iac/modules/` contain reusable Terraform logic.  
Cluster instances in `iac/clusters/<name>/` call the modules with cluster-specific values.  
Never put provider configurations inside modules — only in cluster instances.

When changing a module, validate all cluster instances that call it:
```bash
cd iac/clusters/<name>/<stage> && terraform validate
```

## Two installation paths

### 1. Terraform-managed (bootstrap / platform / vault / apps / vault-config)

| Component | Version location |
|-----------|-----------------|
| Talos Linux | `iac/clusters/<cluster>/bootstrap/main.tf` — `talos_version` |
| Kubernetes | `iac/clusters/<cluster>/bootstrap/main.tf` — `kubernetes_version` |
| Cilium | `iac/clusters/<cluster>/platform/main.tf` — `cilium_version` |
| Longhorn | `iac/clusters/<cluster>/platform/main.tf` — `longhorn_version` |
| Gateway API CRDs | `iac/clusters/<cluster>/platform/main.tf` — `gateway_api_version` |
| ArgoCD | `iac/clusters/server3/apps/main.tf` — `argocd_chart_version` (server3 only) |
| OpenBao | `iac/clusters/server3/vault/main.tf` — `openbao_version` (server3 only) |
| Provisioner image | `gitops/helm-charts/provisioner/values.yaml` — `image.digest` (**not** a `*_version` variable, and **not** Terraform — it is a chart value) |
| Terraform providers | `iac/modules/<module>/versions.tf` — exact pins. `clusters/server3/apps/main.tf` duplicates the helm pin; keep both in step. `modules/vault-config` pins vault `5.11.0` while `modules/apps` stays on `~> 4.0` — separate roots and lock files, deliberately (5.x has the ephemeral KV read and write-only secret arguments) |

To apply a version change: `cd iac/clusters/<cluster>/<stage> && terraform apply -auto-approve`

### 2. ArgoCD-managed (GitOps)

All other apps use the **app-of-apps + ApplicationSet** pattern: **eight stages under `apps/`**, plus three server3-only stages under `server3/apps/`.
- **infra** stage: ESO + supporting K8s resources (ClusterSecretStore)
- **gateway** stage: Traefik + ExternalDNS + ExternalSecret for Unifi credentials
- **observability** stage: k8s-monitoring / Grafana Alloy (all clusters); server3-only LGTM stack (Prometheus, Grafana, Loki, Tempo) under `server3/apps/observability/`
- **iot** stage: InfluxDB2, EMQX, Telegraf, IotInfra — **server1 only**
- **databases** stage: MongoDB — **server1 only**
- **network-policies** stage: default-deny + egress allow-list per namespace — **server1 only**, and deliberately manual-sync
- **dashboards** stage: Headlamp, Hubble UI, Longhorn UI (all clusters); `server3/apps/dashboards/` adds the OpenBao HTTPRoute and homelab-dashboard-ui
- **identity** stage: Authentik + the authentik-blueprints chart — `server3/apps/identity/`, **server3 only**
- **apps** stage: custom apps — miot-bridge-api, interactive-map-feeder-api, qr-manager-api, qr-manager-ui, per-namespace OTel collectors — **server1 only**

Bootstrap is **two manual kubectl applies** on server3:

```bash
kubectl apply -f gitops/argocd-manifests/ArgoCD.yaml      # ArgoCD self-management
kubectl apply -f gitops/argocd-manifests/Bootstrap.yaml   # meta App-of-Apps
```

`Bootstrap.yaml` points at `gitops/argocd-manifests/roots/` with `directory.recurse: true` and manages every Root Application. Root Applications carry `argocd.argoproj.io/sync-wave` annotations that order them:

- **wave 1** — `RootInfra` (ESO + CRDs; must precede any other app's ExternalSecret)
- **wave 2** — `RootGateway` (Traefik + ExternalDNS) · `server3/RootDashboards` (OpenBao HTTPRoute — unblocks server2 ESO reaching `vault.server3.homelab.irha.cz`)
- **wave 3** — `RootObservability` · `server3/RootObservability` · `server3/RootIdentity` · `RootIoT` · `RootDatabases` · `RootDashboards`
- **wave 4** — `RootApps` (custom apps depending on MongoDB + EMQX)
- **wave 5** — `RootNetworkPolicies` (must come after the namespaces its Applications target exist; `CreateNamespace=false`)

For sync waves to wait on child-Application Health (not just creation), ArgoCD's Application CRD health check is restored via a Lua `resource.customizations` entry in `gitops/helm-values/server3/argocd.yaml`. Source: [ArgoCD 1.7→1.8 upgrade notes](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/1.7-1.8).

Each Root Application discovers **ApplicationSets** in `gitops/argocd-manifests/apps/<stage>/`. Each ApplicationSet uses a **list generator** with one element per cluster. Adding a cluster to a stage means adding one `{cluster, clusterServer}` element to each ApplicationSet in that stage and committing. `destination.server` in each template selects the target cluster via `{{clusterServer}}`. Version is `targetRevision` in the ApplicationSet template. ArgoCD auto-syncs on commit.

Server3-specific singleton Applications live in `gitops/argocd-manifests/server3/apps/`:

- `dashboards/OpenBao.yaml` — exposes OpenBao at `vault.server3.homelab.irha.cz` (managed by `roots/server3/RootDashboards.yaml`)
- `observability/` — Prometheus, Grafana, Loki, Tempo (managed by `roots/server3/RootObservability.yaml`)

`ArgoCD.yaml` (self-management) lives at `gitops/argocd-manifests/ArgoCD.yaml` — not under any cluster subdirectory.

Helm values use a two-layer approach:
- **Shared base**: `gitops/helm-values/<name>.yaml` — common across all clusters
- **Cluster overrides**: `gitops/helm-values/<cluster>/<name>.yaml` — cluster-specific values (merged last, wins)

> The `homelab-apps` deploy action rewrites the app values files with `yq` to bump `image.tag`. That **strips blank lines** from the whole file — comments survive, formatting does not. Don't spend effort on blank-line layout in `gitops/helm-values/apps/**` or `gitops/helm-values/server3/homelab-dashboard-ui.yaml`; the next release flattens it.

For custom apps deployed via the `apps` stage, a third layer is used:
- **App-level values**: `gitops/helm-values/apps/<app>/` — shared + env-specific (base.yaml, production.yaml, sandbox.yaml)
- **Shared VARs**: `gitops/helm-values/apps/common/values.yaml` — VAR_* identical for every app, cluster and stage
- **Cluster/stage VARs**: `VAR_CLUSTER`, `VAR_PUBLIC_DOMAIN`, `VAR_SUBDOMAIN` are **not in any values file** — each apps ApplicationSet sets them as `helm.parameters` from the generator (`{{cluster}}`, `{{subdomain}}`). Production passes `VAR_SUBDOMAIN=""`; the chart skips empty VARs so that renders as unset. Adding a cluster needs a generator element, no new values files

Raw Kubernetes manifests live in `gitops/k8s-manifests/<cluster>/<app>/`.

## Version sync rules — MUST follow

When changing any component version:
1. Update the version in the relevant `iac/clusters/<cluster>/<stage>/main.tf` or Application CRD (`targetRevision`)
2. Review the diff between old and new upstream `values.yaml` against your local override files to catch removed or renamed keys

## App documentation rules

- Every app deployed in any cluster **must have a row** in the technology stack table in `docs/architecture.md`.
- Every row must have: Purpose, Clusters (which clusters run it), Managed by, Artifact Hub link (or `—`), Local values links for every cluster-specific file that exists, and Upstream `values.yaml` link (or `—`).
- If an app has no Helm chart (e.g. Gateway API CRDs, Hubble UI built into Cilium), use `—` for Artifact Hub, Local values, and Upstream columns.
- If an app is removed from all clusters, remove its row from the table.
- Apps with per-cluster helm overrides must list all local values files in one row as `shared · server3` or `server1 · server2 · server3` — list only the files that exist. server2 carries platform values only.

## Dependency monitoring (Renovate)

Renovate (Mend hosted GitHub App) watches every pinned version in this repo and reports to a
**Dependency Dashboard** issue. Config: [`renovate.json5`](renovate.json5), validated in CI by
[`renovate-validate.yaml`](.github/workflows/renovate-validate.yaml).

**It opens nothing on its own.** `dependencyDashboardApproval` is set repo-wide, so every update —
including security ones — waits on the dashboard until a human ticks it. `automerge` is off
everywhere and must stay off.

**A merged Renovate PR is not a deployment. This is true twice, and the second is worse:**

| Path | What merging actually does | What deploys it |
|------|---------------------------|-----------------|
| `gitops/` | Changes `targetRevision` in git | Periodic reconciliation **does** run (`timeout.reconciliation: 120s`, verified 2026-09-13 — see the note below), so most changes deploy on their own within ~3 min. Hard Refresh → **one** Sync when they do not |
| `iac/` | Changes a string in a `.tf` file. **Nothing else.** | `terraform apply` in that cluster's module. **For `talos_version` this still does not upgrade anything** — see below |
| `gitops/argocd-manifests/ArgoCD.yaml` | Changes a file **nothing reconciles** | `kubectl -n argocd apply -f` it by hand. No Application sources that directory (`bootstrap` watches `roots/` only) and the Terraform resource has `ignore_changes = [yaml_body]`, so neither GitOps nor `terraform apply` will pick it up |

**The inverse is also true and catches people out: one Hard Refresh is not a contained action.**
Refreshing any app invalidates the repo cache for the whole `repoURL`, so *every* app tracking
`HEAD` that has unsynced commits behind it will reconcile at once. On 2026-09-06 a refresh intended
for `root-databases` alone synced nine apps and deployed a change committed days earlier. Before
refreshing, know what is sitting unsynced: `git log` since the revision the apps report.

An updated `talos_version` sitting merged in git is not installed, and only `terraform plan` will
tell you. The same applies to `cilium_version`, `longhorn_version`, `openbao_version` and
`gateway_api_version`. This exact drift was found live on 2026-09-05: Terraform claimed Gateway API
`1.2.1` while all three clusters ran `1.4.0`. (Both figures are that day's state — the fleet is on
`1.6.2` as of 2026-09-13 and the pin matches.)

**`talos_version` is worse than the others: even `terraform apply` does not install it.** The
variable feeds exactly one place, `machine.install.image`, which the *installer* reads at install
time. Applying a new machine config changes what a future install would use and leaves the running
Talos version untouched — no reboot, no upgrade, and `talosctl version` still reports the old one.
Upgrading a running node is out-of-band:

```sh
talosctl upgrade --preserve --nodes <ip> \
  --image factory.talos.dev/metal-installer/<schematic>:<version>
```

Do **not** bump `talos_secrets_contract` to do it. That variable exists precisely so the OS version
and the PKI generation contract can no longer move together; it is additionally protected by
`ignore_changes`.

Terraform version variables are matched by a custom manager via `# renovate:` comment annotations
directly above each variable — see [`iac/clusters/server1/platform/main.tf`](iac/clusters/server1/platform/main.tf).
**A variable without its annotation is invisible to Renovate**, which looks exactly like being
up to date. Add the annotation whenever you add a version variable.

## Upgrading a chart

1. **ArgoCD-managed**: update `targetRevision` in the Application CRD under `gitops/argocd-manifests/<cluster>/apps/<stage>/<Name>.yaml`
2. **Terraform-managed**: update the `*_version` variable in `iac/clusters/<cluster>/<stage>/main.tf`, then run `terraform apply -auto-approve`
3. Review the diff between old and new upstream `values.yaml` against local override files to catch removed or renamed keys
4. Render both versions against **this repo's** values and diff the output, not just the upstream defaults:
   `helm template <rel> <repo>/<chart> --version <OLD|NEW> -f gitops/helm-values/<chart>.yaml -f gitops/helm-values/<cluster>/<chart>.yaml`
   This is what catches a renamed StatefulSet orphaning a PVC, or a dropped Service port.
5. Upstream `values.yaml` links in `docs/architecture.md` point to the `main` branch — no link update needed on upgrade
6. **Verify against the cluster, not the Synced badge.** A values-only change hits a stale
   multi-source cache and reads `Synced` while serving the old values — hard refresh first.
   **A change that only reaches a PostSync hook Job is worse: it can never show as `OutOfSync`,
   and a hard refresh does not help.** The provisioner Jobs use
   `hook-delete-policy: HookSucceeded`, so no Job exists in the cluster once it has run, and ArgoCD
   only diffs live tracked resources. Trigger an explicit sync per app and check
   `status.operationState.syncResult` for `hookPhase: Succeeded`. Verified 2026-09-13.
7. **Check that the chart version actually pins the image.** Usually it does — loki `18.12.1`
   renders `grafana/loki:3.7.7`, traefik `41.5.0` renders `traefik:v3.7.13` — so one pin covers
   both the templates and the binary. **`mongodb` is the exception and the only Bitnami chart
   here.** Its image block is `bitnami/mongodb:latest` in every chart version, so `targetRevision`
   pins the YAML and says nothing about which mongod runs; the chart's advertised app version is a
   `Chart.yaml` label that moves no binary. Confirm with:
   `helm show values <repo>/<chart> --version <NEW> | sed -n '/^image:/,/^[a-z]/p'`

   Bitnami retired its public catalog in Aug 2025: `bitnami/mongodb` now publishes only `latest`,
   and the versioned tags moved to `bitnamilegacy/`, frozen at 8.0.9. There is no version tag to
   pin to — a digest is the only option, and it is **deliberately not used** (upstream `latest` is
   trusted). The practical consequence: the engine moves on the next *fresh* pull, not on a chart
   bump. `pullPolicy: IfNotPresent` plus the node's cached layer is what holds it steady, so
   **a node rebuild or Talos upgrade is what will move MongoDB across a release boundary**, and
   that upgrades the on-disk data files irreversibly. Check `mongod --version` against the image
   `latest` currently resolves to before any node-level work.

## Vault

OpenBao is deployed via `iac/clusters/server3/vault/` (Terraform-managed, server3 only).
App secrets are stored in OpenBao and synced to all clusters via External Secrets Operator.
After `terraform apply`, run the init ceremony manually (see `iac/clusters/server3/vault/main.tf` header).
See [docs/secrets.md](docs/secrets.md) for the full secrets path inventory and seeding commands per stage.

OpenBao's own configuration (auth methods, policies, identity groups) is Terraform too:
`iac/clusters/server3/vault-config/`, module `iac/modules/vault-config/`.

- **Today it holds only OIDC login via Authentik.** It runs **last** on a fresh server3, after GitOps
  bootstrap, because Authentik generates the OIDC client secret (docs/iac.md step 6).
- **Nothing that must exist before ArgoCD belongs in it** without its own toggle or stage.
- **The older auth config is still hand-made** per docs/iac.md step 3: ESO's `kubernetes-*` mounts,
  `read-secrets`, the provisioner policies and userpass. Move it in deliberately with `terraform
  import`, never by recreating a live mount; a recreated `kubernetes-*` mount breaks every
  ExternalSecret on that cluster.
- **Keep userpass and the root token.** Authentik's secrets come from OpenBao, so OpenBao must stay
  administrable without Authentik.

## Backups — what exists, and what it does not cover

**Take a dump before anything that cannot be rolled back.** Longhorn has no downgrade path,
Kubernetes has no downgrade path, and there is no volume-level restore (see below).

```bash
~/homelab-backups/dump-all.sh     # lives OUTSIDE this repo; credentials come from ./.env
```

It dumps etcd on all three clusters, the Authentik Postgres, MongoDB x2, InfluxDB x2 and an OpenBao
raft snapshot, writes `SHA256SUMS`, uploads to Cloudflare R2 (~300 MB) and verifies the remote copy
with `rclone check --checksum`. **It is run by hand — nothing schedules it**, so its freshness is only
ever as good as the last run. Check the date of the newest directory in `~/homelab-backups/` before
trusting it.

Two things it is not:

- **Not a Longhorn backup.** `backupTarget` is `""`, there are no RecurringJobs or Snapshots, and the
  CSI snapshotter is not installed. There is no point-in-time volume restore. These are logical dumps
  — a rebuild path, not high availability. MinIO was dropped as a backup destination; do not
  re-propose it.
- **Not complete.** Prometheus, Loki, Tempo, Grafana and EMQX are deliberately excluded — the first
  three hold reconstructible telemetry, Grafana is provisioned from git, and EMQX's PVC is broker
  runtime state. See [docs/architecture.md](docs/architecture.md) for the per-cluster table.

The OpenBao raft snapshot is taken with `BAO_TOKEN` from `.env` and **only works while OpenBao is
unsealed** — so dump before a reboot of server3, not after.

## Credentials

Written to `iac/clusters/<cluster>/credentials/` (gitignored) by the bootstrap stage.
Access using:
```bash
export KUBECONFIG=iac/clusters/<cluster>/credentials/kubeconfig
export TALOSCONFIG=iac/clusters/<cluster>/credentials/talosconfig
```

## Operational commands

> **Change the clusters through git, not through commands.** ArgoCD syncs every app with
> `selfHeal` and `prune` enabled, so an imperative change is transient — the next
> reconcile reverts it, usually within minutes. Edit the manifest, commit, sync. An agent
> that fixes something with `kubectl` has not fixed it.
>
> Reading is unrestricted: `kubectl get/describe/logs`, `argocd app get`, and Prometheus
> or Loki queries via the Grafana MCP. Restarting a workload (`kubectl rollout restart`,
> `delete pod`) and reconciling an app (`argocd app sync`) are routine — a controller
> recreates the pod and ArgoCD converges on committed state.
>
> **The exception is anything holding data.** PersistentVolumeClaims, PersistentVolumes,
> Longhorn volumes, namespaces, StatefulSets and CRDs are *not* covered by "git will put
> it back" — Prometheus, Loki, Tempo, MongoDB and InfluxDB2 data lives in Longhorn and
> exists nowhere else. Deleting one is unrecoverable. Ask first, every time.
>
> Permission enforcement lives in the Claude Code harness, not in this repository; the
> operator configures it locally. Treat a denial as a decision, not an obstacle to route
> around — and never edit the permission configuration on the operator's behalf.
>
> **Green does not mean working.** ArgoCD reporting `Synced`/`Healthy` with Running pods
> proves the manifests applied, not that telemetry, traffic or data is flowing. Two
> separate bugs during the k8s-monitoring migration (a scrape gated behind
> `hostMetrics.linuxHosts.enabled`, and an OTLP exporter that could not start) sat green
> for hours while collecting nothing. Verify observability changes by querying the data —
> `count by (cluster) (kube_pod_status_phase)` and the Loki `k8s_cluster_name` label — not
> by reading sync status. (Logs reach Loki over its native OTLP endpoint, so the index
> label is the OTel name `k8s_cluster_name`; `cluster` survives as structured metadata.)

### Run freely (read-only / safe)

```bash
# Terraform
terraform plan
terraform validate
terraform output

# Kubernetes
kubectl get <resource>
kubectl describe <resource>
kubectl logs <pod>

# Talos
talosctl health
talosctl logs <service>
talosctl get disks

# ArgoCD
kubectl get applications -n argocd
kubectl describe application <name> -n argocd

# Git (local only)
git status / git diff / git log
```

### Run freely (intended write operations)

```bash
terraform apply -auto-approve      # version bumps and config changes
sops --encrypt --in-place <file>   # encrypting new secrets

# ArgoCD — force refresh or kill stuck sync
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=normal
kubectl patch application <name> -n argocd --type merge -p '{"operation": null}'
```

### Ask before running (destructive / irreversible)

```bash
terraform destroy
talosctl upgrade
talosctl reset
talosctl wipe disk
kubectl delete <resource>
rm -rf / any deletion of credentials
```

## Adding a new cluster

1. Copy `iac/clusters/server2/` as the template (bootstrap + platform only — no apps stage)
2. Fill in cluster-specific values (IPs, disk selectors, schematic ID) in each `main.tf`
3. Update Cilium `devices: "TODO"` to the correct network interface
4. Bootstrap: run `terraform apply -auto-approve` for bootstrap and platform stages
5. Register the cluster in server3 ArgoCD: `argocd cluster add <context>`
6. Add a `{cluster, clusterServer}` element to each ApplicationSet in `gitops/argocd-manifests/apps/<stage>/*.yaml` and commit — ArgoCD auto-generates all Applications for the new cluster. No manual Root-App apply needed; `Bootstrap.yaml` on server3 already manages all Root Apps.

## Adding a new ArgoCD app

**For apps from `radoslavirha/homelab-apps`** (renamed from `iot-miniservers` 2026-09-14): use its `onboard-to-homelab` skill (`.apm/skills/onboard-to-homelab/`) instead of manually creating files. The skill generates all files below and opens a PR. After merge, seed OpenBao secrets listed in the PR TODO section before first ArgoCD sync. 

For other apps (manual):
1. Create `gitops/argocd-manifests/apps/<stage>/<Name>.yaml` — copy an existing ApplicationSet as template. The list generator already targets all registered clusters.
2. Add helm values at `gitops/helm-values/<name>.yaml` (shared) and `gitops/helm-values/<cluster>/<name>.yaml` (cluster overrides)
3. Add raw manifests to `gitops/k8s-manifests/<cluster>/<name>/` if needed
4. Add a row to the technology stack table in `docs/architecture.md` with all required columns (see App documentation rules above)

## Adding an Authentik application or role

Applications, providers, role groups and policy bindings are **generated**, never clicked together in
the UI. Edit the matrix only:

1. Add or edit an entry in `gitops/helm-values/server3/authentik-blueprints.yaml` — `name`, `title`,
   `hostPrefix`/`host`, optional `basePath`, `roles`, and one `environments` entry per cluster+stage
   (plus `{ stage: local }` for a developer machine).
2. Roles are a ladder, written most-privileged first:
   `- name: admin` / `inherits: editor`, `- name: editor` / `inherits: reader`, `- name: reader`.
   A bare string is a role with no parent. The chart `fail`s on a dangling `inherits`, a cycle, a
   self-inheriting role, a duplicate name, or an application with no roles at all.
3. `helm template gitops/helm-charts/authentik-blueprints -f gitops/helm-values/server3/authentik-blueprints.yaml`
   to check it renders before pushing.
4. Hard Refresh + Sync `authentik-server3` in ArgoCD, then wait — **~15 minutes**, measured
   2026-09-08, not the ~45s this used to claim. Three delays stack: kubelet propagating the ConfigMap
   into the worker's volume (~1 min), Authentik's blueprint discovery timer noticing the changed file
   (~10 min), and the import itself (~4-6 min for this matrix — one transaction, so nothing appears
   until it commits). `kubectl exec deploy/authentik-worker -- ak apply_blueprint
   /blueprints/mounted/cm-authentik-blueprints/homelab-applications.yaml` forces it, but it does not
   finish faster and it will queue behind (or ahead of) the scheduled apply on row locks.
5. Add users to the new groups in the Authentik UI — memberships are deliberately not in git.

A **client** entry (`kind: client` — something a human drives that calls other applications' APIs)
adds `accesses: [<app>, …]` and `redirectUris:` instead of a host: its token's `aud` names each target
and its `roles` claim comes from the groups the human already holds there. A **device** entry
(`kind: device` — a machine) adds `accesses: [{ app: <app>, role: <role> }]` and no redirect URIs; the
chart declares its service account in the target's role group and binds that group to the application.
Several environments still render ONE client, with one secret and one service account in each listed
environment's role group. Its `client_secret` is generated by Authentik — read it from the provider
page in the UI and put it in the device firmware; it is deliberately not in git.

A client or device renders exactly ONE application spanning every environment it lists — one login, one
token, every API. The `roles` claim is `app.role` with no environment in it, so such a token carries the
union of the holder's roles across those environments; with identical roles everywhere that is a no-op.
Each target API needs one trusted-issuer row for that client, the same value in every deployment.

**Blueprints do not prune.** A role removed or renamed in values leaves its group, its members and its
policy binding in place; delete the old group in the UI or it keeps granting access.

Full model, token claims and gotchas: [docs/identity.md](docs/identity.md).

## State backend migration (MinIO)

Once MinIO is running on the server3 cluster:
1. Uncomment the `backend "s3" {}` block in each `main.tf`
2. Run `terraform init -migrate-state` to move local state to MinIO
3. New clusters (server1) can use MinIO from the start — no migration needed
See [docs/iac.md](docs/iac.md) for the full migration sequence.

## Skills (`.apm/skills/`)

- **`sync-docs`** — after any repo change; keeps README.md, AGENTS.md, docs/architecture.md, docs/iac.md in sync
- **`sync-obsidian`** — after any change to clusters, service hostnames, IPs, or app versions; updates `Server/Homelab Overview.md` in Obsidian for IoT planning agents
- **`probe-traffic`** — generate real traffic against a cluster and verify what it produced; use when checking that telemetry actually flows, testing reachability or egress, or validating NetworkPolicy before/after a change

`sync-docs` automatically calls `sync-obsidian` at the end of its procedure. Run `sync-obsidian` standalone when the repo docs are already correct but the Obsidian snapshot is stale.
