# Agent Guidelines — homelab

Kubernetes homelab: three Talos Linux clusters managed with Terraform (IaC) and ArgoCD (GitOps).
See [README.md](README.md) for cluster overview. See [docs/architecture.md](docs/architecture.md) for decisions and roadmap.

All agentic tools (skill, instruction, agents,..) must be added to `.apm` folder. Never update/add `.github`/`.claude`. Example Structure:
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
  clusters/
    helm-values/  Shared Cilium + Longhorn values (all clusters)
    server1/      bootstrap/ platform/ helm-values/
    server2/      bootstrap/ platform/ helm-values/
    server3/      bootstrap/ platform/ vault/ apps/ helm-values/
gitops/
  helm-charts/
    provisioner/            reusable PostSync provisioner Jobs chart (InfluxDB2, EMQX, MongoDB)
  helm-values/
    external-dns.yaml       shared: Unifi webhook provider, sources (gateway-httproute, traefik-proxy, crd), policy
    external-secrets.yaml   shared: installCRDs: true
    headlamp.yaml           shared: httpRoute + clusterRoleBinding
    traefik.yaml            shared: hostNetwork, Gateway API provider, listeners, bare-metal service
    emqx.yaml               shared: replica count, persistence, dashboard envFromSecret
    influxdb2.yaml          shared: org=homelab, existingSecret, Longhorn persistence 25Gi
    mongodb.yaml            shared: root credentials existingSecret, auth enabled
    telegraf.yaml           shared: InfluxDB2 + MQTT outputs, env secretKeyRefs
    prometheus.yaml         shared: TSDB only, remote-write receiver, Longhorn 20Gi, 30d retention
    grafana.yaml            shared: existingSecret grafana-admin, sidecar datasources+dashboards, Longhorn 5Gi
    loki.yaml               shared: Monolithic, filesystem storage, Longhorn 20Gi
    tempo.yaml              shared: local backend, OTLP receivers, metrics generator, Longhorn 20Gi
    otel-gateway.yaml       shared: Deployment mode, otel-contrib, receivers, processors, pipeline topology
    apps/
      common/               values.yaml (cluster-agnostic VAR_PROTOCOL, VAR_MQTT_URL, VAR_MONGODB_URL), production.yaml, sandbox.yaml
      otel-collector/       base.yaml, production.yaml, sandbox.yaml
      miot-bridge-api/  base.yaml, production.yaml, sandbox.yaml
      interactive-map-feeder-api/ base.yaml, production.yaml, sandbox.yaml
      qr-manager-api/   base.yaml, production.yaml, sandbox.yaml
      qr-manager-ui/    base.yaml, production.yaml, sandbox.yaml
    server2/
      apps/
        common/             production.yaml, sandbox.yaml (shared VAR_* for all apps in each namespace)
      provisioner/          influxdb2.yaml, emqx.yaml, mongodb.yaml — provisioner chart values per datastore
      emqx.yaml             server2 EMQX overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides
      headlamp.yaml         hostname: headlamp.server2.home
      influxdb2.yaml        server2 Longhorn storageClass overrides
      mongodb.yaml          server2 overrides
      otel-gateway.yaml     forwarder: single otlp/server3 exporter → otel.server3.home:4317, k8s.cluster.name=server2
      telegraf.yaml         server2 overrides (currently empty)
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip
    server3/
      argocd.yaml           ArgoCD helm overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides (currently empty)
      headlamp.yaml         hostname: headlamp.server3.home
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip, OTLP tracing endpoint
      prometheus.yaml       server3 overrides (currently empty)
      grafana.yaml          server3 overrides: extraSecretMounts for influxdb2-grafana secret
      otel-gateway.yaml     exporters (Loki/Tempo/Prometheus endpoint URLs), k8s.cluster.name=server3
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
      server3/
        RootDashboards.yaml    sync-wave: "2" — App-of-Apps → server3/apps/dashboards/ (OpenBao HTTPRoute)
        RootObservability.yaml sync-wave: "3" — App-of-Apps → server3/apps/observability/ (LGTM stack)
    apps/
      infra/       ESO (AppSet, list generator)
      gateway/     Traefik (AppSet), ExternalDNS (AppSet)
      observability/ OTelGateway (AppSet)
      iot/         InfluxDB2 (AppSet), EMQX (AppSet), Telegraf (AppSet), IotInfra (AppSet, sync-wave: -1)
      databases/   MongoDB (AppSet)
      dashboards/  Headlamp (AppSet), Hubble (AppSet), Longhorn (AppSet)
      apps/        AppsOTelCollector (AppSet), MiotBridgeApi (AppSet), InteractiveMapFeederApi (AppSet), QrManagerApi (AppSet), QrManagerUi (AppSet)
    server3/
      apps/
        dashboards/ OpenBao.yaml   App: vault.server3.home HTTPRoute
        observability/ Prometheus.yaml, Grafana.yaml, Loki.yaml, Tempo.yaml
  k8s-manifests/
    server2/
      cilium/              HTTPRoute: hubble.server2.home → hubble-dashboard:80
      external-secrets/    ClusterSecretStore → remote server3 OpenBao at vault.server3.home
      iot/         ExternalSecret.provisioner-token.yaml (openbao-provision-token; sync-wave -1 via IotInfra)
      influxdb2/   ExternalSecret.yaml, HTTPRoute.yaml
      emqx/        ExternalSecret.yaml, HTTPRoute.yaml, IngressRouteTCP.yaml
      telegraf/    ExternalSecret.telegraf.influxdb2.yaml, ExternalSecret.telegraf.mqtt.yaml
      external-dns/ ExternalSecret (unifi-credentials), DNSEndpoint
      longhorn/    HTTPRoute: longhorn.server2.home → longhorn-frontend:80
      mongodb/     ExternalSecret, IngressRouteTCP, ExternalSecret.provisioner-token.yaml
      miot-bridge-api/ production/ and sandbox/ — ExternalSecret.mqtt.yaml, ExternalSecret.mongodb.yaml
      qr-manager-api/ production/ and sandbox/ — ExternalSecret.mongodb.yaml
      otel-gateway/ ExternalSecret.otel-auth-token.yaml (shared OTLP bearer token pulled from secret/otel-gateway/auth-token)
    server3/
      cilium/              HTTPRoute: hubble.server3.home → hubble-dashboard:80
      external-dns/        ExternalSecret (unifi-credentials), DNSEndpoint (server3.home A record)
      external-secrets/    ClusterSecretStore → local OpenBao
      longhorn/            HTTPRoute: longhorn.server3.home → longhorn-frontend:80
      openbao/             HTTPRoute: vault.server3.home → openbao:8200
      grafana/             ExternalSecret (grafana-admin), ExternalSecret (influxdb2-grafana), datasource ConfigMaps (prometheus/loki/tempo/influxdb2), dashboard ConfigMap (traefik-opentelemetry), HTTPRoute: grafana.server3.home
      otel-gateway/        ExternalSecret.otel-auth-token.yaml (shared OTLP bearer token), HTTPRoute: otel.server3.home, IngressRouteTCP (otel gRPC :4317)
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

### 1. Terraform-managed (bootstrap / platform / vault / apps)

| Component | Version location |
|-----------|-----------------|
| Talos Linux | `iac/clusters/<cluster>/bootstrap/main.tf` — `talos_version` |
| Kubernetes | `iac/clusters/<cluster>/bootstrap/main.tf` — `kubernetes_version` |
| Cilium | `iac/clusters/<cluster>/platform/main.tf` — `cilium_version` |
| Longhorn | `iac/clusters/<cluster>/platform/main.tf` — `longhorn_version` |
| Gateway API CRDs | `iac/clusters/<cluster>/platform/main.tf` — `gateway_api_version` |
| ArgoCD | `iac/clusters/server3/apps/main.tf` — `argocd_chart_version` (server3 only) |
| OpenBao | `iac/clusters/server3/vault/main.tf` — `openbao_version` (server3 only) |

To apply a version change: `cd iac/clusters/<cluster>/<stage> && terraform apply -auto-approve`

### 2. ArgoCD-managed (GitOps)

All other apps use the **app-of-apps + ApplicationSet** pattern with seven stages (six multi-cluster + server3-only LGTM):
- **infra** stage: ESO + supporting K8s resources (ClusterSecretStore)
- **gateway** stage: Traefik + ExternalDNS + ExternalSecret for Unifi credentials
- **observability** stage: OTel Gateway (all clusters); server3-only LGTM stack (Prometheus, Grafana, Loki, Tempo) under `server3/apps/observability/`
- **iot** stage: InfluxDB2 (server2), EMQX (server2), Telegraf (server2), IotInfra (server2)
- **databases** stage: MongoDB (server2)
- **dashboards** stage: Headlamp, Hubble UI, Longhorn UI (server3 · server2); server3-only OpenBao HTTPRoute under `server3/apps/dashboards/`
- **apps** stage: custom apps — miot-bridge-api, interactive-map-feeder-api, qr-manager-api, qr-manager-ui, per-namespace OTel collectors

Bootstrap is **two manual kubectl applies** on server3:

```bash
kubectl apply -f gitops/argocd-manifests/ArgoCD.yaml      # ArgoCD self-management
kubectl apply -f gitops/argocd-manifests/Bootstrap.yaml   # meta App-of-Apps
```

`Bootstrap.yaml` points at `gitops/argocd-manifests/roots/` with `directory.recurse: true` and manages every Root Application. Root Applications carry `argocd.argoproj.io/sync-wave` annotations that order them:

- **wave 1** — `RootInfra` (ESO + CRDs; must precede any other app's ExternalSecret)
- **wave 2** — `RootGateway` (Traefik + ExternalDNS) · `server3/RootDashboards` (OpenBao HTTPRoute — unblocks server2 ESO reaching `vault.server3.home`)
- **wave 3** — `RootObservability` · `server3/RootObservability` · `RootIoT` · `RootDatabases` · `RootDashboards`
- **wave 4** — `RootApps` (custom apps depending on MongoDB + EMQX + OTel Gateway)

For sync waves to wait on child-Application Health (not just creation), ArgoCD's Application CRD health check is restored via a Lua `resource.customizations` entry in `gitops/helm-values/server3/argocd.yaml`. Source: [ArgoCD 1.7→1.8 upgrade notes](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/1.7-1.8).

Each Root Application discovers **ApplicationSets** in `gitops/argocd-manifests/apps/<stage>/`. Each ApplicationSet uses a **list generator** with one element per cluster. Adding a cluster to a stage means adding one `{cluster, clusterServer}` element to each ApplicationSet in that stage and committing. `destination.server` in each template selects the target cluster via `{{clusterServer}}`. Version is `targetRevision` in the ApplicationSet template. ArgoCD auto-syncs on commit.

Server3-specific singleton Applications live in `gitops/argocd-manifests/server3/apps/`:

- `dashboards/OpenBao.yaml` — exposes OpenBao at `vault.server3.home` (managed by `roots/server3/RootDashboards.yaml`)
- `observability/` — Prometheus, Grafana, Loki, Tempo (managed by `roots/server3/RootObservability.yaml`)

`ArgoCD.yaml` (self-management) lives at `gitops/argocd-manifests/ArgoCD.yaml` — not under any cluster subdirectory.

Helm values use a two-layer approach:
- **Shared base**: `gitops/helm-values/<name>.yaml` — common across all clusters
- **Cluster overrides**: `gitops/helm-values/<cluster>/<name>.yaml` — cluster-specific values (merged last, wins)

For custom apps deployed via the `apps` stage, a third layer is used:
- **App-level values**: `gitops/helm-values/apps/<app>/` — shared + env-specific (base.yaml, production.yaml, sandbox.yaml)
- **Cluster+namespace common**: `gitops/helm-values/<cluster>/apps/common/{env}.yaml` — shared VAR_* for all apps in a namespace (e.g. VAR_PUBLIC_DOMAIN, VAR_SUBDOMAIN)

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
- Apps with per-cluster helm overrides must list all local values files in one row as `shared · server3` or `server1 · server2 · server3`.

## Upgrading a chart

1. **ArgoCD-managed**: update `targetRevision` in the Application CRD under `gitops/argocd-manifests/<cluster>/apps/<stage>/<Name>.yaml`
2. **Terraform-managed**: update the `*_version` variable in `iac/clusters/<cluster>/<stage>/main.tf`, then run `terraform apply -auto-approve`
3. Review the diff between old and new upstream `values.yaml` against local override files to catch removed or renamed keys
4. Upstream `values.yaml` links in `docs/architecture.md` point to the `main` branch — no link update needed on upgrade

## Vault

OpenBao is deployed via `iac/clusters/server3/vault/` (Terraform-managed, server3 only).
App secrets are stored in OpenBao and synced to all clusters via External Secrets Operator.
After `terraform apply`, run the init ceremony manually (see `iac/clusters/server3/vault/main.tf` header).
See [docs/secrets.md](docs/secrets.md) for the full secrets path inventory and seeding commands per stage.

## Credentials

Written to `iac/clusters/<cluster>/credentials/` (gitignored) by the bootstrap stage.
Access using:
```bash
export KUBECONFIG=iac/clusters/<cluster>/credentials/kubeconfig
export TALOSCONFIG=iac/clusters/<cluster>/credentials/talosconfig
```

## Operational commands

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

**For apps from `radoslavirha/iot-miniservers`:** use the `onboard-to-homelab` skill from the apps repo instead of manually creating files. The skill generates all files below and opens a PR. After merge, seed OpenBao secrets listed in the PR TODO section before first ArgoCD sync. 

For other apps (manual):
1. Create `gitops/argocd-manifests/apps/<stage>/<Name>.yaml` — copy an existing ApplicationSet as template. The list generator already targets all registered clusters.
2. Add helm values at `gitops/helm-values/<name>.yaml` (shared) and `gitops/helm-values/<cluster>/<name>.yaml` (cluster overrides)
3. Add raw manifests to `gitops/k8s-manifests/<cluster>/<name>/` if needed
4. Add a row to the technology stack table in `docs/architecture.md` with all required columns (see App documentation rules above)
5. Update `docs/iot-miniservers-setup/CLAUDE-app-template.md` is not needed for non-iot-miniservers apps

## State backend migration (MinIO)

Once MinIO is running on the server3 cluster:
1. Uncomment the `backend "s3" {}` block in each `main.tf`
2. Run `terraform init -migrate-state` to move local state to MinIO
3. New clusters (server1) can use MinIO from the start — no migration needed
See [docs/iac.md](docs/iac.md) for the full migration sequence.

## Skills (`.apm/skills/`)

- **`sync-docs`** — after any repo change; keeps README.md, AGENTS.md, docs/architecture.md, docs/iac.md in sync
- **`sync-obsidian`** — after any change to clusters, service hostnames, IPs, or app versions; updates `Server/Homelab Overview.md` in Obsidian for IoT planning agents

`sync-docs` automatically calls `sync-obsidian` at the end of its procedure. Run `sync-obsidian` standalone when the repo docs are already correct but the Obsidian snapshot is stale.
