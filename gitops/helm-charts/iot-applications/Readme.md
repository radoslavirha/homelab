# IoT applications Helm chart

Environment-agnostic chart. No environment-specific files live here.
All values (image tags, replicas, config content, variables) are in `helm-values/{env}`.

## Values structure

```
helm-values/server1/apps/
  vars/common.yaml              ← `vars:` shared by every app and stage (protocol, mqtt.url, mongodb.url)
  vars/{env}.yaml               ← `vars:` per stage (cluster, domain); Helm deep-merges both
  {app}/base.yaml               ← shared: image, resources, labels, services, ingress, templates.file/path
  {app}/{env}.yaml              ← env-specific: image.tag, templates.<name>.content + .secrets
```

Every `vars` value lives in `vars/` — none come from ApplicationSet parameters — so a template's variables can always be found next to it.

## Applications configuration

See `values.yaml` for full schema with comments.

Example minimal app:

```yaml
apps:
  my-app:
    image:
      repository: my-repo/my-app
      tag: 1.0.0
    labels:
      component: api
      partOf: iot
    services:
      http:
        enabled: true
        protocol: TCP
        port: 80
        targetPort: 4000
    ingress:
      enabled: true
      serviceRef: http
```

deploys to: `https://<labels.component>.<vars.domain>/<ingress.pathName or app name>` — or `ingress.hostname` when set. The stage is part of `vars.domain` (`sandbox.server1...`), so it sits left of the component.

Services are named: `{component}-{partOf}-{app}-{serviceName}` (e.g. `api-iot-my-app-http`).

## Config templates

A config file is written as a template in the env-specific values file — **no files inside the chart** — and rendered by [External Secrets Operator](https://external-secrets.io/) (ESO), not by the pod. For each template the chart emits an `ExternalSecret`; ESO fetches the template's secrets from OpenBao, renders the file into the Secret `<identifier>-tpl-<name>`, and the main container mounts it at `path`.

```yaml
# helm-values/server1/apps/my-app/production.yaml
apps:
  my-app:
    templates:
      config:
        secrets:                         # optional; name → OpenBao entry
          mongodbPassword:
            key: <cluster>/<env>/my-app-mongodb
            property: mongodb-password
        content: |
          {
            "url": "{{ .vars.protocol }}://{{ .app.host }}/{{ .app.pathName }}",
            "pass": {{ .secrets.mongodbPassword | toJson }}
          }
```

The syntax is Go `text/template` with Sprig — the same as Helm — so `if`, `default`, `printf` and `toJson` are available. Pipe a secret through `toJson` whenever it may contain a quote or a backslash; `toJson` also adds the surrounding quotes.

**A typo cannot reach a pod.** ESO renders with `missingkey=error`: an unknown `{{ .NAME }}` or a missing OpenBao property fails the ExternalSecret (`SecretSyncedError`, the missing key named in its events) and leaves the previous Secret — and the running pods — untouched. On a first install the pod waits in `ContainerCreating` until the Secret exists; under ArgoCD the ExternalSecret's sync-wave `-1` stops the sync there first.

**Changes reach the pods through Reloader.** ESO re-renders when the content or a `vars` value changes, and — for a template with secrets — on every `configRender.refreshInterval` (default `1h`), which is how a credential rotated in OpenBao arrives. The file is read once, at pod start, so set `annotations.reloader.stakater.com/auto: "true"` on the app; [Stakater Reloader](https://github.com/stakater/Reloader) then rolls the workload whenever the rendered Secret changes. A refresh that renders the same bytes does not restart anything.

A template **without** `secrets` is anchored on a UUID generator (ESO rejects an ExternalSecret with nothing to fetch) and rendered `OnChange`, so it is never rewritten on a timer.

### Variables

A template reads three maps. The prefix says where a value comes from:

| Map | Source |
|---|---|
| `.vars.*` | the top-level `vars` map, whole — a new key needs no chart change |
| `.secrets.*` | the keys of `templates.<name>.secrets`, from OpenBao via `configRender.secretStore` |
| `.app.*` | built-ins derived from the app definition, below |

| Built-in | Source |
|---|---|
| `.app.name` | `apps[name]` |
| `.app.group` | `labels.partOf` |
| `.app.component` | `labels.component` |
| `.app.namespace` | Helm `$.Release.Namespace` — the stage |
| `.app.containerPort` | `ingress.serviceRef` → `services[ref].targetPort` (default 80) |
| `.app.pathName` | `ingress.pathName` when the key is set (`""` included), else `apps[name]` |
| `.app.host` | the HTTPRoute hostname: `ingress.hostname`, else `<labels.component>.<vars.domain>`. Only when `ingress.enabled` |

The built-ins exist so a config cannot drift from what the chart deploys: `.app.host`, `.app.pathName` and `.app.containerPort` come from the same fields as the HTTPRoute and the Service.

### Validating the rendered config (`validate`)

ESO guarantees every variable exists, not that the result is a config the app accepts. An app that parses its own config at boot catches a bad one itself — the Ts.ED APIs do, so a broken config fails the process and the pod CrashLoops. nginx cannot: it has no JSON parser, so a UI whose `config.json` is missing a value starts fine, answers `/healthz`, goes Ready, and serves a blank page while ArgoCD reports `Healthy`.

Set `validate: true` on the template for apps in the second group:

```yaml
apps:
  my-ui:
    templates:
      config:
        file: config.json
        path: /usr/share/nginx/html/config.json
        subPath: config.json
        validate: true
```

This generates an initContainer that runs the app's own schema against the rendered file. A rejected config gives `Init:CrashLoopBackOff` — and with `maxUnavailable: 0`, the previous pod keeps serving. The reason is in the container log:

```bash
kubectl logs <pod> -c <identifier>-<template>-validate
```

The image defaults to `<image.repository>-config-validator:<image.tag>`, so the app and its validator are bumped by the same `deploy.json` change and cannot come from different commits. Override with the map form (`repository`, `tag`, `args`) when that convention does not fit.

The validator mounts the rendered Secret at `/config` itself, so `path` and `subPath` — which describe the *main* container's mount — do not affect it.

## Runtime environment secrets (`secretRefs`)

For an app that reads a credential from its **environment** at runtime — not from its config file — `secretRefs` injects existing Kubernetes Secrets into the main container with `envFrom`. homelab-dashboard-ui uses it: nginx attaches `SECRET_UNIFI_API_KEY` in `proxy_set_header`, and the key must never enter the `config.json` it serves to the browser.

```yaml
apps:
  my-app:
    secretRefs:
      - name: my-app-credentials        # K8s Secret, e.g. from an ExternalSecret in k8s-manifests
        keys:
          - SECRET_MY_APP_API_KEY
```

Config files do not use `secretRefs`; they take `templates.<name>.secrets`.

## Argo Rollouts

Set `rollout.enabled: true` with `rollout.strategy: canary` or `rollout.strategy: blueGreen` to emit a Rollout instead of a Deployment. See `values.yaml` for full schema including service pair references.
