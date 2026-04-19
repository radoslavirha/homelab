# GitOps

ArgoCD manifests, Helm values overrides, and raw Kubernetes manifests for all clusters.

ArgoCD runs only on the **server3** cluster and manages workloads on all clusters via `destination.server`.

## Structure

```
gitops/
  argocd-manifests/
    ArgoCD.yaml             ArgoCD self-management Application (cluster-agnostic)
    server3/
      RootInfra.yaml        Infra App-of-Apps for server3 (ESO + OpenBao route)
      RootGateway.yaml      Gateway App-of-Apps for server3 (Traefik + ExternalDNS)
      apps/
        infra/    ESO.yaml, OpenBao.yaml
        gateway/  Traefik.yaml, ExternalDNS.yaml
  helm-values/
    external-dns.yaml       shared: Unifi webhook provider, sources, policy
    external-secrets.yaml   shared: installCRDs: true
    traefik.yaml            shared: hostNetwork, Gateway API provider, listeners, bare-metal service
    server3/
      argocd.yaml           ArgoCD helm overrides
      external-dns.yaml     domainFilters, txtOwnerId
      external-secrets.yaml cluster-specific overrides (currently empty)
      traefik.yaml          dashboard hostname/IP, externalIPs, statusAddress.ip
  k8s-manifests/
    server3/
      external-dns/        ExternalSecret — unifi-credentials (pulls from local OpenBao)
      external-secrets/    ClusterSecretStore → openbao.openbao.svc.cluster.local
      openbao/             HTTPRoute: vault.server3.home (Traefik → OpenBao:8200)
  shared/
    helm-charts/      Custom Helm charts used across clusters
```

## App-of-apps pattern

Each cluster has two root Applications: **infra** and **gateway**.

| Stage | Apps | Why this order |
|-------|------|----------------|
| infra | ESO, OpenBao HTTPRoute | ESO must be running before ExternalDNS can pull the Unifi API key |
| gateway | Traefik, ExternalDNS | Traefik GatewayClass is needed for HTTPRoutes; ExternalDNS needs the ESO-synced secret |

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

1. Create `gitops/argocd-manifests/<cluster>/apps/<stage>/<Name>.yaml` — copy an existing Application as template.
2. Add shared Helm values at `gitops/helm-values/<name>.yaml` if applicable.
3. Add cluster-specific overrides at `gitops/helm-values/<cluster>/<name>.yaml`.
4. Add raw manifests to `gitops/k8s-manifests/<cluster>/<name>/` if needed.
5. The root Application for that cluster+stage will auto-discover the new file (`directory.recurse: true`).

## Adding a new cluster

1. Add root Application manifests under `gitops/argocd-manifests/<cluster>/`.
2. Add cluster-specific helm-values overrides under `gitops/helm-values/<cluster>/`.
3. Add raw K8s manifests under `gitops/k8s-manifests/<cluster>/`.
4. Register the cluster in ArgoCD: `argocd cluster add <context> --name <cluster>`; update `destination.server` in leaf Applications.
