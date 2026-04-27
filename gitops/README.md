# GitOps

ArgoCD manifests, Helm values overrides, and raw Kubernetes manifests for all clusters.

ArgoCD runs only on the **server3** cluster and manages workloads on all clusters via `destination.server`.

## Structure

```
gitops/
  argocd-manifests/
    ArgoCD.yaml             ArgoCD self-management Application (manual apply #1)
    Bootstrap.yaml          Meta App-of-Apps (manual apply #2) — discovers roots/
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
      infra/       ESO.yaml
      gateway/     Traefik.yaml, ExternalDNS.yaml
      observability/ OTelGateway.yaml
      iot/         IotInfra.yaml, InfluxDB2.yaml, EMQX.yaml, Telegraf.yaml
      databases/   MongoDB.yaml
      dashboards/  Headlamp.yaml, Hubble.yaml, Longhorn.yaml
      apps/        AppsOTelCollector.yaml, MiotBridgeApiIot.yaml, InteractiveMapFeederApiIot.yaml
    server3/
      apps/
        dashboards/   OpenBao.yaml
        observability/ Prometheus.yaml, Grafana.yaml, Loki.yaml, Tempo.yaml
  helm-values/
    external-dns.yaml       shared: Unifi webhook provider, sources, policy
    external-secrets.yaml   shared: installCRDs: true
    emqx.yaml               shared: MQTT broker, Longhorn persistence, emqxConfig rules
    headlamp.yaml           shared: httpRoute + clusterRoleBinding
    influxdb2.yaml          shared: org=homelab, existingSecret, Longhorn persistence 25Gi
    mongodb.yaml            shared: standalone, existingSecret, Longhorn persistence 10Gi
    traefik.yaml            shared: hostNetwork, Gateway API provider, listeners, mqtt + mongodb entrypoints, bare-metal service
    server2/
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides (currently empty)
      emqx.yaml             cluster-specific overrides (currently empty)
      headlamp.yaml         hostname: headlamp.server2.home
      influxdb2.yaml        cluster-specific overrides (currently empty)
      mongodb.yaml          cluster-specific overrides (currently empty)
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip
    server3/
      argocd.yaml           ArgoCD helm overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides (currently empty)
      headlamp.yaml         hostname: headlamp.server3.home
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip
  k8s-manifests/
    server2/
      cilium/              HTTPRoute: hubble.server2.home → hubble-dashboard:80
      external-dns/        ExternalSecret (unifi-credentials), DNSEndpoint (server2.home A record)
      external-secrets/    ClusterSecretStore → OpenBao on server3
      emqx/                ExternalSecret (emqx-credentials), HTTPRoute: mqtt.server2.home, IngressRouteTCP: port 1883
      influxdb2/           ExternalSecret (admin creds from OpenBao), HTTPRoute: influx.server2.home
      longhorn/            HTTPRoute: longhorn.server2.home → longhorn-frontend:80
      mongodb/             ExternalSecret (root password from OpenBao), IngressRouteTCP: port 27017
    server3/
      cilium/              HTTPRoute: hubble.server3.home → hubble-dashboard:80
      external-dns/        ExternalSecret (unifi-credentials), DNSEndpoint (server3.home A record)
      external-secrets/    ClusterSecretStore → local OpenBao
      grafana/             ExternalSecret (grafana-admin), datasource ConfigMaps (prometheus/loki/tempo), HTTPRoute: grafana.server3.home
      longhorn/            HTTPRoute: longhorn.server3.home → longhorn-frontend:80
      openbao/             HTTPRoute: vault.server3.home → openbao:8200
      otel-gateway/        HTTPRoute: otel.server3.home, IngressRouteTCP (otel gRPC :4317)
```

## App-of-apps pattern

`Bootstrap.yaml` is a meta App-of-Apps that recursively discovers every Root Application under `roots/`. Each Root App carries an `argocd.argoproj.io/sync-wave` annotation; ArgoCD waits for every Root in wave N to reach **Healthy** before starting wave N+1.

Application-CRD health assessment is enabled by a Lua `resource.customizations` entry in [gitops/helm-values/server3/argocd.yaml](helm-values/server3/argocd.yaml). Without it, Root-level waves would only order *creation* of child ApplicationSets, not workload readiness. Reference: [ArgoCD 1.7→1.8 upgrade notes](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/1.7-1.8).

|Wave|Root App|Stage|Why this wave|
|----|--------|-----|-------------|
|1|`roots/RootInfra.yaml`|infra|ESO + CRDs — any other app's `ExternalSecret` fails to apply until these CRDs exist|
|2|`roots/RootGateway.yaml`|gateway|Traefik installs the Gateway every HTTPRoute/TCPRoute in later waves references. ExternalDNS needs ESO (wave 1) for its Unifi secret|
|2|`roots/server3/RootDashboards.yaml`|server3 singleton|OpenBao HTTPRoute at `vault.server3.home` — parallel with RootGateway; unblocks server2 ClusterSecretStore|
|3|`roots/RootObservability.yaml`|observability|OTel Gateway — needs Traefik (wave 2) + ESO `otel-auth-token`|
|3|`roots/server3/RootObservability.yaml`|server3 observability|Prometheus, Grafana (needs ESO admin secret), Loki, Tempo|
|3|`roots/RootIoT.yaml`|iot|IotInfra, InfluxDB2, EMQX, Telegraf — Telegraf self-orders with resource-level sync-wave `"1"` to wait for InfluxDB2/EMQX post-sync provisioner Jobs|
|3|`roots/RootDatabases.yaml`|databases|MongoDB — needs ESO + Traefik TCPRoute|
|3|`roots/RootDashboards.yaml`|dashboards|Headlamp, Hubble, Longhorn UI — need Traefik HTTPRoutes|
|4|`roots/RootApps.yaml`|apps|Custom apps: miot-bridge-api needs MongoDB + EMQX, apps-otel-collector needs OTel Gateway|

Each ApplicationSet uses a list generator — one element per cluster. Adding a cluster means adding `{cluster, clusterServer}` to each ApplicationSet and committing.

## Helm values — two-layer approach

Helm values are split into a shared base and per-cluster overrides, both listed in `valueFiles` (cluster-specific file last — wins on conflict):

```
gitops/helm-values/<app>.yaml               ← shared across all clusters
gitops/helm-values/<cluster>/<app>.yaml     ← cluster-specific overrides
```

Only create a cluster-specific file when there are actual overrides. The shared file is always included.

## Bootstrap sequence

Run from the repo root on **server3** after completing all Terraform stages in `docs/iac.md`. Two manual applies — `Bootstrap.yaml` orders all Root Apps through sync waves 1 → 4.

### Server3 (ArgoCD runs here)

```bash
export KUBECONFIG=iac/clusters/server3/credentials/kubeconfig

# 1. ArgoCD self-management
kubectl apply -f gitops/argocd-manifests/ArgoCD.yaml

# 2. Bootstrap meta App-of-Apps
kubectl apply -f gitops/argocd-manifests/Bootstrap.yaml

# Watch progress:
kubectl get applications -n argocd -w
```

Secrets under `secret/server3/...` must already be seeded in OpenBao before step 2 (argocd admin hash, grafana admin, external-dns unifi key) — seeded by `docs/iac.md` step 4.

### Server1 / Server2

After Terraform + OpenBao setup + `argocd cluster add` (see `docs/iac.md`):

1. Add `{cluster, clusterServer}` element to each ApplicationSet list generator:

   ```text
   gitops/argocd-manifests/apps/infra/ESO.yaml
   gitops/argocd-manifests/apps/gateway/Traefik.yaml
   gitops/argocd-manifests/apps/gateway/ExternalDNS.yaml
   gitops/argocd-manifests/apps/observability/OTelGateway.yaml
   gitops/argocd-manifests/apps/iot/IotInfra.yaml
   gitops/argocd-manifests/apps/iot/InfluxDB2.yaml
   gitops/argocd-manifests/apps/iot/EMQX.yaml
   gitops/argocd-manifests/apps/iot/Telegraf.yaml
   gitops/argocd-manifests/apps/databases/MongoDB.yaml
   gitops/argocd-manifests/apps/dashboards/Headlamp.yaml
   gitops/argocd-manifests/apps/dashboards/Hubble.yaml
   gitops/argocd-manifests/apps/dashboards/Longhorn.yaml
   ```

2. Commit + push. Bootstrap on server3 already owns every Root App; ArgoCD generates new per-cluster `Application`s automatically. **Do not re-run any manual `kubectl apply` for Root Apps.**

3. Ordering within each generated Application is handled by resource-level sync waves (ExternalSecret `-50`/`-1`/`0`, HTTPRoute `100`, Telegraf `1`, OpenBao HTTPRoute `200`). Retries converge the cross-cluster timing.

4. Seed OpenBao secrets **before** committing the cluster element:

   - `secret/<cluster>/external-dns` (Unifi API key)
   - `secret/<cluster>/influxdb2` (admin-password, admin-token)
   - `secret/<cluster>/emqx` (dashboard-username, dashboard-password)
   - `secret/<cluster>/mongodb` (root-password)
   - `secret/<cluster>/provisioner-token` (long-lived write token)

   See `docs/secrets.md` for exact `bao kv put` commands.

## Adding a new app

1. Create `gitops/argocd-manifests/apps/<stage>/<Name>.yaml` — copy an existing ApplicationSet as template. The list generator already targets all registered clusters.
2. Add shared Helm values at `gitops/helm-values/<name>.yaml` if applicable.
3. Add cluster-specific overrides at `gitops/helm-values/<cluster>/<name>.yaml` when needed.
4. Add raw manifests to `gitops/k8s-manifests/<cluster>/<name>/` if needed.
5. Commit — ArgoCD auto-discovers the new ApplicationSet via `directory.recurse: true` on the root Application.

## Adding a new cluster

1. Bootstrap the cluster (Talos + platform) via Terraform in `iac/clusters/<cluster>/`.
2. Register the cluster in server3 ArgoCD: `argocd cluster add <context> --name <cluster>`.
3. Add `{cluster, clusterServer}` to the list generator in each ApplicationSet under `gitops/argocd-manifests/apps/infra/`, `apps/gateway/`, `apps/iot/`, `apps/databases/`, and `apps/dashboards/`.
4. Add cluster-specific helm-values overrides under `gitops/helm-values/<cluster>/` if needed.
5. Add raw K8s manifests under `gitops/k8s-manifests/<cluster>/` if needed.
6. Commit — ArgoCD auto-generates all Applications for the new cluster.
