---
description: "GitOps rules for ArgoCD manifests, raw manifests and Helm values: waves, AppSets, manual-sync exceptions, per-app traps"
applyTo: "gitops/argocd-manifests/**,gitops/k8s-manifests/**,gitops/helm-values/**"
---

# GitOps (`gitops/`)

## How ArgoCD is wired

- Bootstrap is two manual applies on server3: `gitops/argocd-manifests/ArgoCD.yaml` (self-management),
  then `Bootstrap.yaml` (meta App-of-Apps over `roots/`, `directory.recurse: true`).
- **Nothing reconciles `ArgoCD.yaml`.** No Application sources that directory and Terraform ignores
  its body. A change to it goes out with `kubectl -n argocd apply -f` by hand.
- Root Applications are ordered by `argocd.argoproj.io/sync-wave`. A Lua health check for the
  Application CRD (in `gitops/helm-values/server3/argocd.yaml`) makes a wave wait for child health,
  not just creation:
  - wave 1 `RootInfra` — ESO and its CRDs must precede every other ExternalSecret
  - wave 2 `RootGateway`, `server3/RootDashboards` (the OpenBao route that server1/server2 ESO need)
  - wave 3 `RootObservability`, `server3/RootObservability`, `server3/RootIdentity`, `RootIoT`,
    `RootDatabases`, `RootDashboards`
  - wave 4 `RootApps` (custom apps, need MongoDB + EMQX), `RootHousehold`
  - wave 5 `RootNetworkPolicies` — its namespaces must already exist (`CreateNamespace=false`)
- Each Root discovers ApplicationSets in `gitops/argocd-manifests/apps/<ArgoCD stage>/`. Each uses a
  list generator with one `{cluster, clusterServer}` element per cluster; the chart version is
  `targetRevision` in the template. server3-only singletons live in `gitops/argocd-manifests/server3/apps/`.
- `household/` (Mealie, Open WebUI on server1; Ollama on server2) is raw manifests with no
  `targetRevision`: the version is the image tag in the Deployment, which Renovate's `kubernetes`
  manager watches. These are third-party singletons, kept out of the `apps` ArgoCD stage, which is only
  for our own apps rendered by the `app` chart.
- `network-policies/` Applications are **manual-sync on purpose** — `selfHeal` would undo the emergency
  rollback. Change them only through the `network-egress` skill.

## Helm values

- Two layers: shared `gitops/helm-values/<name>.yaml`, then `gitops/helm-values/<cluster>/<name>.yaml`
  (merged last, wins). Custom apps add a third layer — see the app-chart rule.
- A version bump goes through the `upgrade-components` skill: render old and new against this repo's
  values and diff, before pushing.
- **Traefik `:8080` stays.** Under `hostNetwork` + `externalIPs` the kubelet cannot probe `:80`;
  removing `:8080` took server2's ingress down. The socket answering `404` is by design — assert `404`,
  not a closed port.
- server1's Traefik exposes `1883`/`8883`/`27017` for the IoT estate. server2's has deliberately **no**
  `ports:` block — read the comment in the file before adding one.

## Raw manifests (`gitops/k8s-manifests/<cluster>/<app>/`)

- **App credentials are never here.** The `app` chart's ExternalSecret renders them into the config
  file. `qr-manager-api/sandbox/` is intentionally empty (see its README).
- Mealie's and Open WebUI's `ExternalSecret.oidc.yaml` read an Authentik client secret copied into
  OpenBao by hand once. Open WebUI's sits at sync-wave 200 so a missing key cannot block the app.
- Open WebUI's Postgres image is pgvector on Debian: `fsGroup: 999`, not an Alpine value.
- Mealie's and Open WebUI's namespaces are outside the default-deny set; no NetworkPolicy work.
- **Ollama has no authentication.** Its only gate is `Middleware.ipallowlist.yaml`, which admits
  server1's node address alone. Never widen it.
- Grafana alerting (`server3/grafana/`): `alerting-notifications` holds the ONE contact point and the
  WHOLE policy tree. `policies:` replaces, never merges.
- A UI guarded by the Authentik proxy outpost needs three things in its own namespace: a
  `Middleware.authentik.yaml`, an `ExtensionRef` filter on its HTTPRoute, and a second route rule
  sending `/outpost.goauthentik.io/` to the outpost. Procedure: the `authentik-blueprints` skill.

## After any change here

- Add or remove the app's row in the technology stack table of `docs/architecture.md` (the `sync-docs`
  skill lists the columns).
- Verify against the cluster, not the badge: compare the app's `status.sync.revision(s)` with
  `git rev-parse origin/main`, then check the workload itself.
