# GitOps

ArgoCD manifests, Helm values overrides, and raw Kubernetes manifests for all clusters.

ArgoCD runs only on the **server3** cluster and manages workloads on all clusters via `destination.server`.

## Structure

```
gitops/
  argocd-manifests/
    ArgoCD.yaml             ArgoCD self-management Application (cluster-agnostic)
    RootInfra.yaml          App-of-Apps → apps/infra/ (all clusters)
    RootGateway.yaml        App-of-Apps → apps/gateway/ (all clusters)
    RootDatastores.yaml     App-of-Apps → apps/datastores/ (all clusters)
    RootDashboards.yaml     App-of-Apps → apps/dashboards/ (all clusters)
    apps/
      infra/       ESO.yaml
      gateway/     Traefik.yaml, ExternalDNS.yaml
      datastores/  InfluxDB2.yaml
      dashboards/  Headlamp.yaml, Hubble.yaml, Longhorn.yaml
    server3/
      RootDashboards.yaml   App-of-Apps → server3/apps/dashboards/ (server3-only singletons)
      apps/
        dashboards/   OpenBao.yaml
  helm-values/
    external-dns.yaml       shared: Unifi webhook provider, sources, policy
    external-secrets.yaml   shared: installCRDs: true
    headlamp.yaml           shared: httpRoute + clusterRoleBinding
    influxdb2.yaml          shared: org=homelab, existingSecret, Longhorn persistence 25Gi
    traefik.yaml            shared: hostNetwork, Gateway API provider, listeners, bare-metal service
    server2/
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides (currently empty)
      headlamp.yaml         hostname: headlamp.server2.home
      influxdb2.yaml        cluster-specific overrides (currently empty)
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
      influxdb2/           ExternalSecret (admin creds from OpenBao), HTTPRoute: influx.server2.home
      longhorn/            HTTPRoute: longhorn.server2.home → longhorn-frontend:80
    server3/
      cilium/              HTTPRoute: hubble.server3.home → hubble-dashboard:80
      external-dns/        ExternalSecret (unifi-credentials), DNSEndpoint (server3.home A record)
      external-secrets/    ClusterSecretStore → local OpenBao
      longhorn/            HTTPRoute: longhorn.server3.home → longhorn-frontend:80
      openbao/             HTTPRoute: vault.server3.home → openbao:8200
```

## App-of-apps pattern

There are three multi-cluster root Applications and one server3-only root Application:

| Root Application | Stage | Apps | Why this order |
|-----------------|-------|------|----------------|
| `RootInfra.yaml` | infra | ESO | ESO must be running before ExternalDNS can pull the Unifi API key |
| `RootGateway.yaml` | gateway | Traefik, ExternalDNS | Traefik GatewayClass is needed for HTTPRoutes; ExternalDNS needs the ESO-synced secret |
| `RootDatastores.yaml` | datastores | InfluxDB2 | Datastores depend on ESO for secret sync; secrets must be seeded in OpenBao first |
| `RootDashboards.yaml` | dashboards | Headlamp, Hubble, Longhorn UI | UI layer — depends on Traefik for HTTPRoutes |
| `server3/RootDashboards.yaml` | server3 singletons | OpenBao HTTPRoute | server3-only; Traefik must exist before HTTPRoute can bind |

Each stage uses ApplicationSets with a list generator — one element per cluster. Adding a cluster means adding `{cluster, clusterServer}` to each ApplicationSet and committing.

## Helm values — two-layer approach

Helm values are split into a shared base and per-cluster overrides, both listed in `valueFiles` (cluster-specific file last — wins on conflict):

```
gitops/helm-values/<app>.yaml               ← shared across all clusters
gitops/helm-values/<cluster>/<app>.yaml     ← cluster-specific overrides
```

Only create a cluster-specific file when there are actual overrides. The shared file is always included.

## Bootstrap sequence

Run from the repo root after completing all Terraform stages in `docs/iac.md`.

### Server3 (ArgoCD runs here)

```bash
# 1. Apply ArgoCD self-management + infra stage
kubectl apply -f gitops/argocd-manifests/ArgoCD.yaml
kubectl apply -f gitops/argocd-manifests/RootInfra.yaml
# Wait for ESO + ClusterSecretStore to become ready before continuing:
kubectl wait --for=condition=Ready clusterSecretStore/openbao -n external-secrets --timeout=120s

# 2. Seed OpenBao secrets for the gateway stage
#    ⚠️  PREREQUISITE: secret/server3/external-dns must exist in OpenBao.
#    See docs/secrets.md → "<cluster>/external-dns" for the exact command.
#    ExternalDNS ExternalSecret syncs on first start — secret must exist before RootGateway.yaml is applied.
#    OpenBao is not yet exposed via Traefik at this point — use port-forward.
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
bao login                                      # enter root token
bao kv put secret/server3/external-dns api-key=<unifi-api-key>
# Verify: bao kv get secret/server3/external-dns

# 3. Apply gateway stage
kubectl apply -f gitops/argocd-manifests/RootGateway.yaml
# ArgoCD auto-syncs Traefik + ExternalDNS. OpenBao is now accessible at vault.server3.home.

# 4. Apply server3-specific singleton Applications (OpenBao HTTPRoute)
#    Applied once — ArgoCD self-heals from then on.
kubectl apply -f gitops/argocd-manifests/server3/RootDashboards.yaml

# 5. Apply datastores stage
#    ⚠️  PREREQUISITE: secret/server3/influxdb2 and secret/server3/provisioner-token
#    must exist in OpenBao before this step. ESO syncs these on first sync —
#    if the paths are missing the pod will crashloop.
#    See docs/secrets.md → "<cluster>/influxdb2" and "<cluster>/provisioner-token".
#    Verify: bao kv list secret/server3
kubectl apply -f gitops/argocd-manifests/RootDatastores.yaml

# 6. Apply dashboards stage (Headlamp, Hubble, Longhorn UI)
kubectl apply -f gitops/argocd-manifests/RootDashboards.yaml
```

### Server1 / Server2

Run after completing the Terraform + OpenBao setup and `argocd cluster add` in `docs/iac.md`.

```bash
# Add the cluster to each ApplicationSet's list generator and commit + push.
# ArgoCD auto-generates Applications as each file is committed.
#
# Files to update (add one element per file):
#   gitops/argocd-manifests/apps/infra/ESO.yaml
#   gitops/argocd-manifests/apps/gateway/Traefik.yaml
#   gitops/argocd-manifests/apps/gateway/ExternalDNS.yaml
#   gitops/argocd-manifests/apps/datastores/InfluxDB2.yaml
#   gitops/argocd-manifests/apps/dashboards/Headlamp.yaml
#   gitops/argocd-manifests/apps/dashboards/Hubble.yaml
#   gitops/argocd-manifests/apps/dashboards/Longhorn.yaml
#
# Add under spec.generators[0].list.elements in each file:
#   - cluster: <cluster>
#     clusterServer: <server-url>   # from: argocd cluster list
#
# Recommended order: infra → gateway → datastores → dashboards.
# After infra: wait for ClusterSecretStore to be Ready before committing the next stage.
#
# Stage prerequisites — seed these in OpenBao BEFORE committing the stage:
#   gateway stage:    secret/<cluster>/external-dns
#   datastores stage: secret/<cluster>/influxdb2
#                     secret/<cluster>/provisioner-token
# See docs/secrets.md for exact bao kv put commands and verification steps.
```

## Adding a new app

1. Create `gitops/argocd-manifests/apps/<stage>/<Name>.yaml` — copy an existing ApplicationSet as template. The list generator already targets all registered clusters.
2. Add shared Helm values at `gitops/helm-values/<name>.yaml` if applicable.
3. Add cluster-specific overrides at `gitops/helm-values/<cluster>/<name>.yaml` when needed.
4. Add raw manifests to `gitops/k8s-manifests/<cluster>/<name>/` if needed.
5. Commit — ArgoCD auto-discovers the new ApplicationSet via `directory.recurse: true` on the root Application.

## Adding a new cluster

1. Bootstrap the cluster (Talos + platform) via Terraform in `iac/clusters/<cluster>/`.
2. Register the cluster in server3 ArgoCD: `argocd cluster add <context> --name <cluster>`.
3. Add `{cluster, clusterServer}` to the list generator in each ApplicationSet under `gitops/argocd-manifests/apps/infra/`, `apps/gateway/`, `apps/datastores/`, and `apps/dashboards/`.
4. Add cluster-specific helm-values overrides under `gitops/helm-values/<cluster>/` if needed.
5. Add raw K8s manifests under `gitops/k8s-manifests/<cluster>/` if needed.
6. Commit — ArgoCD auto-generates all Applications for the new cluster.
