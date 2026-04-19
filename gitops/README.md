# GitOps

ArgoCD manifests, Helm values overrides, and raw Kubernetes manifests for all clusters.

**Not yet populated.** Content will be migrated from the per-cluster repos as each cluster is onboarded.

## Structure

```
gitops/
  helm-values/
    server1/          App helm value overrides for server1 cluster
    server2/          App helm value overrides for server2 cluster
    server3/          ArgoCD + app helm value overrides for server3 cluster
  argocd-manifests/
    server3/          All ArgoCD Application CRDs (destination.server targets the relevant cluster)
  k8s-manifests/
    server1/          Raw Kubernetes resources for server1
    server2/          Raw Kubernetes resources for server2
    server3/          Raw Kubernetes resources for server3 (HTTPRoutes, ExternalSecrets, etc.)
  shared/
    helm-charts/      Custom Helm charts used across clusters (e.g. iot-applications)
```

ArgoCD runs only on the server3 cluster. `destination.server` in each Application selects which cluster the workload deploys to. A root-level shared values file can be added under `gitops/helm-values/` for content common across clusters.

## ArgoCD repo URL

All Application manifests will reference `repoURL: https://github.com/radoslavirha/homelab`.
The `path:` in each Application scopes it to `gitops/clusters/<cluster>/...`.
