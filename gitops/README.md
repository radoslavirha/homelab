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
    RootDashboards.yaml     App-of-Apps → apps/dashboards/ (all clusters)
    apps/
      infra/      ESO.yaml
      gateway/    Traefik.yaml, ExternalDNS.yaml
      dashboards/ Headlamp.yaml, Hubble.yaml, Longhorn.yaml
    server3/
      RootDashboards.yaml   App-of-Apps → server3/apps/dashboards/ (server3-only singletons)
      apps/
        dashboards/   OpenBao.yaml
  helm-values/
    external-dns.yaml       shared: Unifi webhook provider, sources, policy
    external-secrets.yaml   shared: installCRDs: true
    headlamp.yaml           shared: httpRoute + clusterRoleBinding
    traefik.yaml            shared: hostNetwork, Gateway API provider, listeners, bare-metal service
    server3/
      argocd.yaml           ArgoCD helm overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides (currently empty)
      headlamp.yaml         hostname: headlamp.server3.home
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip
  k8s-manifests/
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

## ExternalDNS secret — must be seeded before applying the gateway stage

The gateway stage deploys ExternalDNS, which immediately tries to sync `unifi-credentials` from OpenBao via an `ExternalSecret`. The secret **must exist in OpenBao before** you apply `RootGateway.yaml`.

At this point Traefik is not up yet, so use `kubectl port-forward`:

```bash
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
bao login                                        # enter root token
bao kv put secret/server3/external-dns api-key=<unifi-api-key>
# Verify: bao kv get secret/server3/external-dns
```

Each cluster has its own path:

| Cluster | OpenBao path | Key |
|---------|-------------|-----|
| server3 | `secret/server3/external-dns` | `api-key` |

Once seeded, apply the gateway stage — ESO will create the K8s `unifi-credentials` Secret on first sync.

## Adding a new app

1. Create `gitops/argocd-manifests/apps/<stage>/<Name>.yaml` — copy an existing ApplicationSet as template. The list generator already targets all registered clusters.
2. Add shared Helm values at `gitops/helm-values/<name>.yaml` if applicable.
3. Add cluster-specific overrides at `gitops/helm-values/<cluster>/<name>.yaml` when needed.
4. Add raw manifests to `gitops/k8s-manifests/<cluster>/<name>/` if needed.
5. Commit — ArgoCD auto-discovers the new ApplicationSet via `directory.recurse: true` on the root Application.

## Adding a new cluster

1. Bootstrap the cluster (Talos + platform) via Terraform in `iac/clusters/<cluster>/`.
2. Register the cluster in server3 ArgoCD: `argocd cluster add <context> --name <cluster>`.
3. Add `{cluster, clusterServer}` to the list generator in each ApplicationSet under `gitops/argocd-manifests/apps/infra/`, `apps/gateway/`, and `apps/dashboards/`.
4. Add cluster-specific helm-values overrides under `gitops/helm-values/<cluster>/` if needed.
5. Add raw K8s manifests under `gitops/k8s-manifests/<cluster>/` if needed.
6. Commit — ArgoCD auto-generates all Applications for the new cluster.
