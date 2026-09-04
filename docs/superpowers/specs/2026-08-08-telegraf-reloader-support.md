# Spec — Telegraf: automatic restart on credential rotation

**Status:** open · **Raised by:** the Stakater Reloader rollout (that plan has since been deleted as complete; Reloader itself is deployed on all three clusters and described in `docs/architecture.md`) · **Blocks:** nothing, Telegraf works — rotation is manual

## Problem

Telegraf on server2 reads its InfluxDB2 token and MQTT credentials from environment variables:

```yaml
# gitops/helm-values/telegraf.yaml
env:
  - name: INFLUXDB2_TOKEN
    valueFrom:
      secretKeyRef: { name: telegraf-influxdb2-credentials, key: INFLUXDB2_TOKEN }
  - name: MQTT_USERNAME / MQTT_PASSWORD
    valueFrom:
      secretKeyRef: { name: telegraf-mqtt-credentials, ... }
```

Environment variables are frozen at container start. When ESO syncs a rotated credential from OpenBao, the running Telegraf keeps using the old one and silently stops writing to InfluxDB2 or stops consuming MQTT until someone restarts it by hand.

Every other affected workload in the repo is handled by Stakater Reloader via `reloader.stakater.com/auto: "true"`. Telegraf cannot be: **Reloader reads that annotation from the workload metadata**, and the influxdata `telegraf` chart (pinned `1.8.69`) exposes no way to set it.

```yaml
# charts/telegraf/templates/deployment.yaml — upstream, unchanged
metadata:
  name: {{ include "telegraf.fullname" . }}
  labels:
    {{- include "telegraf.labels" . | nindent 4 }}
    # ← no annotations block, and no values key feeding one
```

Available annotation keys in the chart are `podAnnotations` (pod template), `service.annotations` and `serviceAccount.annotations` — none of which Reloader looks at.

**Scope note:** the chart already puts `checksum/config` on its pod template for its own rendered ConfigMap, so *config* changes do restart Telegraf. Only the **Secret** case is unhandled.

## Goal

A rotated `telegraf-influxdb2-credentials` or `telegraf-mqtt-credentials` restarts Telegraf without human action, using the same mechanism as every other workload in the repo.

## Options

### A. Upstream PR to influxdata/helm-charts — preferred

Add a `deploymentAnnotations` values key, mirroring what `external-dns` (`deploymentAnnotations`) and `traefik` (`deployment.annotations`) already do. The change is four lines:

```yaml
# templates/deployment.yaml
metadata:
  name: {{ include "telegraf.fullname" . }}
  labels:
    {{- include "telegraf.labels" . | nindent 4 }}
  {{- with .Values.deploymentAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
```

```yaml
# values.yaml
## Annotations applied to the Deployment resource (not the pod template).
## Used by controllers such as Stakater Reloader.
deploymentAnnotations: {}
```

Uncontroversial, additive, default-off. Once released, this repo bumps `targetRevision` in `gitops/argocd-manifests/apps/iot/Telegraf.yaml` and adds the annotation to `gitops/helm-values/telegraf.yaml` — deleting the TODO block there.

Cost: PR review latency, entirely outside our control.

### B. Kustomize-with-Helm patch in the Telegraf Application

ArgoCD can render the chart through kustomize and patch the annotation in locally. Works immediately, no upstream dependency.

Cost: the Telegraf Application stops being a plain multi-source Helm app and becomes the only kustomize-rendered app in the repo, requiring `kustomize.buildOptions: --enable-helm` on the ArgoCD repo-server. A structural exception carried for one annotation.

### C. Post-rotation manual restart — current state

```bash
kubectl rollout restart deploy/telegraf -n telegraf
```

Documented in `docs/secrets.md`. Costs nothing, relies on whoever rotates the credential remembering.

### D. Rejected — Telegraf's own config reload

Telegraf's `--watch-config` re-reads the config file, but `$INFLUXDB2_TOKEN` is expanded from the **process** environment, which a config reload does not refresh. Does not solve it.

## Decision

**C now, A next.** Ship the Reloader work with the manual restart documented, then open the upstream PR. Revisit B only if the PR stalls and a rotation actually bites.

## Acceptance criteria

- [ ] `gitops/helm-values/telegraf.yaml` carries `deploymentAnnotations.reloader.stakater.com/auto: "true"` with no TODO block
- [ ] `helm template` of the pinned chart version shows the annotation on `Deployment.metadata.annotations`
- [ ] Rotating `secret/server2/telegraf-influxdb2` in OpenBao and force-syncing the ExternalSecret produces a new Telegraf pod without manual intervention
- [ ] `docs/secrets.md` drops the Telegraf manual-restart paragraph
- [ ] `docs/superpowers/plans/2026-08-05-stakater-reloader.md` "Known gap — telegraf" section marked resolved

## References

- Chart: <https://github.com/influxdata/helm-charts/tree/master/charts/telegraf> (pinned `1.8.69` in `gitops/argocd-manifests/apps/iot/Telegraf.yaml`)
- Reloader annotation semantics: <https://github.com/stakater/Reloader#usage>
- Prior art in this repo: `deploymentAnnotations` in `gitops/helm-values/external-dns.yaml`
