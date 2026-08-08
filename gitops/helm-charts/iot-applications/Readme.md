# IoT applications Helm chart

Environment-agnostic chart. No environment-specific files live here.
All values (image tags, replicas, config content, variables) are in `helm-values/{env}`.

## Values structure

```
helm-values/
  {app}.yaml                    ← shared: image, resources, labels, services, ingress, templates.file/path
helm-values/{env}/
    {app}.yaml                  ← env-specific: replicas, templates.content (jinja2 config body)
    variables.yaml              ← VAR_* values injected into jinja2 at runtime
```

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

deploys to: `{{ SUBDOMAIN if defined }}.{{ component }}.{{ VAR_PUBLIC_DOMAIN }}/{{ partOf }}/{{ app-name }}`

Services are named: `{component}-{partOf}-{app}-{serviceName}` (e.g. `api-iot-my-app-http`).

## Jinja2 config templates

Containers can have files mounted at startup via a jinja2 init container. Config template content is defined as a multiline string in env-specific values files — **no files inside the chart**.

The file is rendered once, at pod start. Set `annotations.reloader.stakater.com/auto: "true"` on the app so [Stakater Reloader](https://github.com/stakater/Reloader) restarts the pod whenever the generated ConfigMap — or any Secret in `secretRefs` — changes. Without it, a changed config or a rotated credential is picked up only on the next manual restart.

```yaml
# helm-values/iot/production/my-app.yaml
apps:
  my-app:
    templates:
      config:
        content: |
          {
            "url": "{{ VAR_PROTOCOL }}://{{ COMPONENT }}.{{ VAR_PUBLIC_DOMAIN }}/..."
          }
```

### Injected variables

All `VAR_*` and `SECRET_*` keys from values files are passed as env vars to the jinja2 init container.

#### Automatically injected

| Variable | Source |
|---|---|
| `APPLICATION` | `apps[name]` |
| `CONTAINER_PORT` | `apps[name].ingress.serviceRef` → `services[ref].targetPort` |
| `CONTAINER_UDP_PORT` | `apps[name].udpIngress.serviceRef` → `services[ref].targetPort` (only when `udpIngress` is configured) |
| `COMPONENT` | `apps[name].labels.component` |
| `APPLICATION_GROUP` | `apps[name].labels.partOf` |
| `NAMESPACE` | Helm `$.Release.Namespace` |

### Validating the rendered config (`validate`)

The rendered file is never checked. An app that parses its own config at boot catches a bad one itself — the Ts.ED APIs do, so a broken config fails the process and the pod CrashLoops. nginx cannot: it has no JSON parser, so a UI whose `config.json` is missing a value starts fine, answers `/healthz`, goes Ready, and serves a blank page while ArgoCD reports `Healthy`.

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

This generates a second initContainer, immediately after the Jinja2 one for that template, which runs the app's own schema against the rendered output. A rejected config gives `Init:CrashLoopBackOff` — and with `maxUnavailable: 0`, the previous pod keeps serving. The reason is in the container log:

```bash
kubectl logs <pod> -c <identifier>-<template>-validate
```

The image defaults to `<image.repository>-config-validator:<image.tag>`, so the app and its validator are bumped by the same `deploy.json` change and cannot come from different commits. Override with the map form (`repository`, `tag`, `args`) when that convention does not fit.

The validator reads `/config/<file>` from the same emptyDir the Jinja2 container wrote to, so `path` and `subPath` — which describe the *main* container's mount — do not affect it.

## Secrets injection (`secretRefs`)

Kubernetes Secrets can be injected into both the Jinja2 init container (for config file rendering) and the main application container (for runtime access) via `secretRefs`.

```yaml
# helm-values/iot/my-app.yaml
apps:
  my-app:
    secretRefs:
      - name: my-app-mqtt-credentials   # K8s Secret name (same in every namespace)
        keys:
          - SECRET_MQTT_MY_APP_USERNAME
          - SECRET_MQTT_MY_APP_PASSWORD
```

### Key naming convention

Secret keys must follow the `SECRET_<SERVICE>_<APP>_<FIELD>` pattern (e.g. `SECRET_MQTT_MIOT_BRIDGE_USERNAME`). This scopes keys per-app, avoiding collisions when multiple apps share a namespace.

### How keys are injected

| Target | Mechanism | Resulting env var |
|---|---|---|
| Jinja2 init container | `env.valueFrom.secretKeyRef` | `JINJA_VAR_SECRET_MQTT_MY_APP_USERNAME` |
| Main app container | `envFrom.secretRef` | `SECRET_MQTT_MY_APP_USERNAME` |

The init container receives the `JINJA_VAR_` prefix automatically — the template uses the bare key name:

```json
"username": "{{ SECRET_MQTT_MY_APP_USERNAME }}"
```

### Creating secrets

Create a SealedSecret in `k8s-manifests/iot/{env}/` with keys matching the `keys` list. The SealedSecret controller decrypts it into a K8s Secret of the same name in the target namespace.

```bash
# Example: seal a secret for the sandbox namespace
kubectl create secret generic my-app-mqtt-credentials \
  --from-literal=SECRET_MQTT_MY_APP_USERNAME=myuser \
  --from-literal=SECRET_MQTT_MY_APP_PASSWORD=mypass \
  --namespace sandbox --dry-run=client -o yaml \
  | kubeseal -o yaml > k8s-manifests/iot/sandbox/SealedSecret.my-app-mqtt-credentials.yaml
```

## Argo Rollouts

Set `rollout.enabled: true` with `rollout.strategy: canary` or `rollout.strategy: blueGreen` to emit a Rollout instead of a Deployment. See `values.yaml` for full schema including service pair references.
