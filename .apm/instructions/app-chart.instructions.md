---
description: "Rules for the in-repo app chart and the custom-app values it renders"
applyTo: "gitops/helm-charts/app/**,gitops/helm-values/server1/apps/**,gitops/helm-values/server3/homelab-dashboard-ui/**"
---

# The `app` chart and custom-app values

One release renders ONE custom app (release name = app name, every value top-level, no `apps:`
wrapper): Deployment or Rollout, Services, HTTPRoute, and config files rendered by ESO into a Secret.

## Values layout

- Per app: `gitops/helm-values/server1/apps/<app>/values.yaml` (shared) plus `values-production.yaml` /
  `values-sandbox.yaml`. The homelab-apps `deploy.json` for each app points at
  `values-<env>.yaml` → `.image.tag`.
- Template variables: `gitops/helm-values/server1/apps/vars/common.yaml` (same for every app and
  environment) plus `vars/<env>.yaml` (`cluster`, `domain`), loaded after the app files and deep-merged
  into `vars:`. They are files, not ApplicationSet `helm.parameters`, on purpose: whoever edits a config
  template must be able to find every variable it reads.
- `vars.domain` carries the environment — `sandbox.server1.homelab.irha.cz`, production is the bare
  cluster domain — and builds every HTTPRoute hostname as `<component>.<domain>`.
- **The homelab-apps deploy action rewrites these files with `yq` to bump `image.tag`, which strips
  every blank line in the file.** Comments survive, formatting does not. Do not spend effort on
  blank-line layout here.

## Config templates

`templates.<name>.content` is Go template syntax reading `.vars.*`, `.secrets.*` (declared in
`templates.<name>.secrets`) and `.app.*` built-ins. ESO renders it — missing keys fail the render
strictly. `templates.<name>.validate: true` adds an initContainer that runs the app's own schema
against the RENDERED config, image `<image.repository>-config-validator:<image.tag>`. Use it for apps
that cannot validate their own config (the nginx UIs); the APIs fail their own boot and leave it unset.

## Annotations — two keys, two targets

- `annotations` land on the **workload** metadata. Put `reloader.stakater.com/auto` there. There is no
  `checksum/config`: Reloader is the only restart mechanism.
- `podAnnotations` land on the **pod template**. Anything Alloy reads (`logs.grafana.com/*`,
  `resource.opentelemetry.io/*`) belongs there; in `annotations` it fails silently.
- The chart injects `resource.opentelemetry.io/service.name` and `.version` (from `image.tag`) on every
  pod. A `podAnnotations` entry overrides either.

## Health

`livenessProbe`, `readinessProbe`, `startupProbe`, `lifecycle` (preStop sleep) and
`terminationGracePeriodSeconds` are opt-in per app, never chart defaults. Paths: `/health/live` and
`/health/ready` for the Ts.ED APIs, `/healthz` for the nginx UIs. These paths are excluded from access
logs and emit no telemetry.

## Network

Apps in `production`/`sandbox` run under default-deny. A new dependency or port needs the
`network-egress` skill, in the same change.
