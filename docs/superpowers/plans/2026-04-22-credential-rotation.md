# Credential Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add scheduled credential rotation for InfluxDB2 tokens and EMQX passwords so they are automatically cycled on a schedule with zero manual steps and zero disruption to running pods.

**Architecture:** CronJobs in the `iot` namespace call each datastore's API to cycle credentials, then write the new value to OpenBao. ESO (refreshInterval: 5m) picks up the change within 5 minutes and updates the K8s Secret. Reloader detects the Secret change and triggers a rolling restart of any annotated Deployment (Telegraf).

**Tech Stack:** Kubernetes CronJob (alpine:3.20 + curl + jq), stakater/Reloader Helm chart, External Secrets Operator, OpenBao KV v2

---

## File Structure

**New files:**
- `gitops/argocd-manifests/apps/infra/Reloader.yaml` — ApplicationSet deploying Reloader to server3 + server2
- `gitops/helm-values/reloader.yaml` — shared Reloader helm values (`watchGlobally: true`)
- `gitops/k8s-manifests/server2/influxdb2/CronJob.rotate.yaml` — InfluxDB2 rotation CronJob (delete old token + create new)
- `gitops/k8s-manifests/server2/emqx/CronJob.rotate.yaml` — EMQX rotation CronJob (in-place password update)

**Modified files:**
- `gitops/argocd-manifests/apps/iot/Telegraf.yaml` — `sync-wave: "1"` already applied (fix for credential race on first deploy — InfluxDB2/EMQX PostSync Jobs must complete before Telegraf ExternalSecrets sync)
- `gitops/helm-values/telegraf.yaml` — add `reloader.stakater.com/auto: "true"` to `podAnnotations`
- `gitops/k8s-manifests/server2/telegraf/ExternalSecret.telegraf.influxdb2.yaml` — `refreshInterval: 1h` → `5m`
- `gitops/k8s-manifests/server2/telegraf/ExternalSecret.telegraf.mqtt.yaml` — `refreshInterval: 1h` → `5m`
- `docs/architecture.md` — add Reloader row to technology stack table
- `docs/provisioning.md` — update rotation note from "future plans" to "implemented"
- `AGENTS.md` — add `Reloader.yaml` to `apps/infra/` in layout tree, add `reloader.yaml` to shared helm-values

---

### Task 1: Deploy Reloader via ArgoCD infra ApplicationSet

**Files:**
- Create: `gitops/argocd-manifests/apps/infra/Reloader.yaml`
- Create: `gitops/helm-values/reloader.yaml`

- [ ] **Step 1: Create the Reloader ApplicationSet**

```yaml
# gitops/argocd-manifests/apps/infra/Reloader.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: reloader
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - cluster: server3
            clusterServer: https://kubernetes.default.svc
          - cluster: server2
            clusterServer: https://192.168.1.201:6443
  template:
    metadata:
      name: reloader-{{cluster}}
    spec:
      project: default
      sources:
        - repoURL: https://stakater.github.io/stakater-charts
          chart: reloader
          targetRevision: 2.2.11
          helm:
            releaseName: reloader
            valueFiles:
              - $values/gitops/helm-values/reloader.yaml
        - repoURL: https://github.com/radoslavirha/homelab
          targetRevision: HEAD
          ref: values
      destination:
        server: '{{clusterServer}}'
        namespace: reloader
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
        automated:
          selfHeal: true
          prune: true
```

- [ ] **Step 2: Create shared Reloader helm values**

```yaml
# gitops/helm-values/reloader.yaml
reloader:
  watchGlobally: true
```

- [ ] **Step 3: Commit**

```bash
git add gitops/argocd-manifests/apps/infra/Reloader.yaml gitops/helm-values/reloader.yaml
git commit -m "feat(infra): deploy Reloader to server2 + server3"
```

- [ ] **Step 4: Apply the ApplicationSet to server3 ArgoCD (runs on server3, manages both clusters)**

```bash
export KUBECONFIG=iac/clusters/server3/credentials/kubeconfig
kubectl apply -f gitops/argocd-manifests/apps/infra/Reloader.yaml
```

- [ ] **Step 5: Verify Reloader pods are running on both clusters**

```bash
# server3
kubectl get deploy reloader -n reloader
# Expected: reloader   1/1   1   ...

# server2
export KUBECONFIG=iac/clusters/server2/credentials/kubeconfig
kubectl get deploy reloader -n reloader
# Expected: reloader   1/1   1   ...
```

---

### Task 2: Annotate Telegraf Deployment for Reloader

**Files:**
- Modify: `gitops/helm-values/telegraf.yaml:7`

- [ ] **Step 1: Update podAnnotations in shared Telegraf helm values**

Change line 7 from `podAnnotations: {}` to:

```yaml
podAnnotations:
  reloader.stakater.com/auto: "true"
```

- [ ] **Step 2: Commit**

```bash
git add gitops/helm-values/telegraf.yaml
git commit -m "feat(telegraf): enable Reloader auto-restart on Secret change"
```

- [ ] **Step 3: Verify annotation is applied after ArgoCD syncs**

```bash
export KUBECONFIG=iac/clusters/server2/credentials/kubeconfig
kubectl get deploy telegraf -n telegraf \
  -o jsonpath='{.spec.template.metadata.annotations}' | jq
# Expected: {"reloader.stakater.com/auto":"true"}
```

---

### Task 3: Shorten ESO refreshInterval for Telegraf secrets

**Files:**
- Modify: `gitops/k8s-manifests/server2/telegraf/ExternalSecret.telegraf.influxdb2.yaml:11`
- Modify: `gitops/k8s-manifests/server2/telegraf/ExternalSecret.telegraf.mqtt.yaml:11`

- [ ] **Step 1: Update refreshInterval in both ExternalSecrets**

`ExternalSecret.telegraf.influxdb2.yaml` — change `refreshInterval: 1h` to `refreshInterval: 5m`

`ExternalSecret.telegraf.mqtt.yaml` — change `refreshInterval: 1h` to `refreshInterval: 5m`

- [ ] **Step 2: Commit**

```bash
git add gitops/k8s-manifests/server2/telegraf/ExternalSecret.telegraf.influxdb2.yaml \
        gitops/k8s-manifests/server2/telegraf/ExternalSecret.telegraf.mqtt.yaml
git commit -m "feat(telegraf): shorten ESO refreshInterval to 5m for rotation propagation"
```

---

### Task 4: InfluxDB2 rotation CronJob

**Files:**
- Create: `gitops/k8s-manifests/server2/influxdb2/CronJob.rotate.yaml`

InfluxDB2 tokens **cannot** be updated in-place. The API does not return the token value after creation. The rotation pattern is:
1. Find the token by description → get its ID
2. Delete the old token by ID
3. Fetch org ID and bucket ID (already exist — no re-creation needed)
4. Create a new token with the same permissions
5. Write the new token value to OpenBao

The CronJob runs in the `iot` namespace so it can access the same Secrets used by the provisioner.

- [ ] **Step 1: Create the CronJob manifest**

```yaml
# gitops/k8s-manifests/server2/influxdb2/CronJob.rotate.yaml
---
# InfluxDB2 rotation CronJob: Telegraf write token
# Runs on schedule. On each run:
#   1. Deletes the existing "telegraf-write" token
#   2. Creates a new write-only token scoped to the "loxone" bucket
#   3. Writes the new token to OpenBao: secret/server2/telegraf-influxdb2
# ESO refreshInterval on the consumer ExternalSecret must be <= 5m for fast propagation.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: influxdb2-rotate-telegraf
  namespace: iot
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          automountServiceAccountToken: false
          containers:
            - name: rotator
              image: alpine:3.20
              env:
                - name: INFLUX_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: influxdb2
                      key: admin-token
                - name: BAO_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: openbao-provision-token
                      key: token
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -e
                  apk add --no-cache curl jq > /dev/null

                  INFLUX_HOST="http://influxdb2.iot.svc.cluster.local"
                  ORG="homelab"
                  BUCKET="loxone"
                  TOKEN_DESC="telegraf-write"
                  BAO_HOST="http://vault.server3.home"

                  # Find existing token ID
                  EXISTING_ID=$(curl -sf \
                    -H "Authorization: Token ${INFLUX_TOKEN}" \
                    "${INFLUX_HOST}/api/v2/authorizations?org=${ORG}" \
                    | jq -r --arg desc "${TOKEN_DESC}" \
                      '.authorizations[] | select(.description==$desc) | .id' | head -1)

                  if [ -n "${EXISTING_ID}" ]; then
                    echo "Deleting old token '${TOKEN_DESC}' (${EXISTING_ID})..."
                    curl -sf -X DELETE \
                      -H "Authorization: Token ${INFLUX_TOKEN}" \
                      "${INFLUX_HOST}/api/v2/authorizations/${EXISTING_ID}"
                    echo "Deleted."
                  else
                    echo "No existing token '${TOKEN_DESC}' found — creating fresh."
                  fi

                  # Get org ID
                  ORG_ID=$(curl -sf \
                    -H "Authorization: Token ${INFLUX_TOKEN}" \
                    "${INFLUX_HOST}/api/v2/orgs?org=${ORG}" | jq -r '.orgs[0].id')

                  # Get bucket ID (must already exist)
                  BUCKET_ID=$(curl -sf \
                    -H "Authorization: Token ${INFLUX_TOKEN}" \
                    "${INFLUX_HOST}/api/v2/buckets?org=${ORG}&name=${BUCKET}" \
                    | jq -r '.buckets[0].id')

                  if [ -z "${BUCKET_ID}" ] || [ "${BUCKET_ID}" = "null" ]; then
                    echo "ERROR: bucket '${BUCKET}' not found. Run provisioner first."
                    exit 1
                  fi

                  # Create new write-only token
                  NEW_TOKEN=$(curl -sf -X POST \
                    -H "Authorization: Token ${INFLUX_TOKEN}" \
                    -H "Content-Type: application/json" \
                    "${INFLUX_HOST}/api/v2/authorizations" \
                    -d "{
                      \"description\": \"${TOKEN_DESC}\",
                      \"orgID\": \"${ORG_ID}\",
                      \"permissions\": [{
                        \"action\": \"write\",
                        \"resource\": { \"type\": \"buckets\", \"id\": \"${BUCKET_ID}\", \"orgID\": \"${ORG_ID}\" }
                      }]
                    }" | jq -r '.token')

                  # Write new token to OpenBao
                  curl -sf -X POST \
                    -H "X-Vault-Token: ${BAO_TOKEN}" \
                    -H "Content-Type: application/json" \
                    "${BAO_HOST}/v1/secret/data/server2/telegraf-influxdb2" \
                    -d "{\"data\": {\"token\": \"${NEW_TOKEN}\"}}"

                  echo "Token '${TOKEN_DESC}' rotated and written to OpenBao."
```

- [ ] **Step 2: Commit**

```bash
git add gitops/k8s-manifests/server2/influxdb2/CronJob.rotate.yaml
git commit -m "feat(influxdb2): add telegraf token rotation CronJob (daily 2 AM)"
```

- [ ] **Step 3: Verify CronJob is registered after ArgoCD sync**

```bash
export KUBECONFIG=iac/clusters/server2/credentials/kubeconfig
kubectl get cronjob influxdb2-rotate-telegraf -n iot
# Expected: influxdb2-rotate-telegraf   0 2 * * *   ...
```

- [ ] **Step 4: Trigger a manual test run and verify the token was rotated**

```bash
# Manually trigger the CronJob
kubectl create job --from=cronjob/influxdb2-rotate-telegraf influxdb2-rotate-test -n iot

# Watch the job logs
kubectl logs -f -l job-name=influxdb2-rotate-test -n iot
# Expected last line: Token 'telegraf-write' rotated and written to OpenBao.

# Verify old token is gone and a new one exists (admin token needed)
INFLUX_TOKEN=$(kubectl get secret influxdb2 -n iot -o jsonpath='{.data.admin-token}' | base64 -d)
curl -s -H "Authorization: Token ${INFLUX_TOKEN}" \
  http://influxdb2.iot.svc.cluster.local/api/v2/authorizations?org=homelab \
  | jq '[.authorizations[] | select(.description=="telegraf-write") | {id, status}]'
# Expected: one token with status: active

# Clean up test job
kubectl delete job influxdb2-rotate-test -n iot
```

---

### Task 5: EMQX rotation CronJob

**Files:**
- Create: `gitops/k8s-manifests/server2/emqx/CronJob.rotate.yaml`

EMQX supports in-place password updates via `PUT` — no delete-recreate needed. The rotation pattern:
1. Generate a new random 24-char password
2. `PUT` to update the `telegraf` user's password in-place
3. Write the new password to OpenBao

- [ ] **Step 1: Create the CronJob manifest**

```yaml
# gitops/k8s-manifests/server2/emqx/CronJob.rotate.yaml
---
# EMQX rotation CronJob: Telegraf MQTT user password
# Runs on schedule (1h offset from InfluxDB2 rotation). On each run:
#   1. Generates a new random 24-char password
#   2. Updates the "telegraf" MQTT user password in-place (PUT)
#   3. Writes the new password to OpenBao: secret/server2/telegraf-mqtt
# ESO refreshInterval on the consumer ExternalSecret must be <= 5m for fast propagation.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: emqx-rotate-telegraf
  namespace: iot
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          automountServiceAccountToken: false
          containers:
            - name: rotator
              image: alpine:3.20
              env:
                - name: EMQX_USER
                  valueFrom:
                    secretKeyRef:
                      name: emqx-credentials
                      key: EMQX_DASHBOARD__DEFAULT_USERNAME
                - name: EMQX_PASS
                  valueFrom:
                    secretKeyRef:
                      name: emqx-credentials
                      key: EMQX_DASHBOARD__DEFAULT_PASSWORD
                - name: BAO_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: openbao-provision-token
                      key: token
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -e
                  apk add --no-cache curl jq > /dev/null

                  EMQX_HOST="http://emqx.iot.svc.cluster.local:18083"
                  MQTT_USER="telegraf"
                  BAO_HOST="http://vault.server3.home"

                  # Verify user exists before attempting rotation
                  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                    -u "${EMQX_USER}:${EMQX_PASS}" \
                    "${EMQX_HOST}/api/v5/authentication/password_based:built_in_database/users/${MQTT_USER}")

                  if [ "$HTTP_CODE" != "200" ]; then
                    echo "ERROR: MQTT user '${MQTT_USER}' not found (HTTP ${HTTP_CODE}). Run provisioner first."
                    exit 1
                  fi

                  # Generate new password and update user in-place
                  NEW_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)

                  curl -sf -X PUT \
                    -u "${EMQX_USER}:${EMQX_PASS}" \
                    -H "Content-Type: application/json" \
                    "${EMQX_HOST}/api/v5/authentication/password_based:built_in_database/users/${MQTT_USER}" \
                    -d "{\"password\": \"${NEW_PASS}\"}"

                  echo "MQTT user '${MQTT_USER}' password updated."

                  # Write new credentials to OpenBao
                  curl -sf -X POST \
                    -H "X-Vault-Token: ${BAO_TOKEN}" \
                    -H "Content-Type: application/json" \
                    "${BAO_HOST}/v1/secret/data/server2/telegraf-mqtt" \
                    -d "{\"data\": {\"username\": \"${MQTT_USER}\", \"password\": \"${NEW_PASS}\"}}"

                  echo "MQTT credentials for '${MQTT_USER}' rotated and written to OpenBao."
```

- [ ] **Step 2: Commit**

```bash
git add gitops/k8s-manifests/server2/emqx/CronJob.rotate.yaml
git commit -m "feat(emqx): add telegraf MQTT password rotation CronJob (daily 3 AM)"
```

- [ ] **Step 3: Verify CronJob is registered after ArgoCD sync**

```bash
export KUBECONFIG=iac/clusters/server2/credentials/kubeconfig
kubectl get cronjob emqx-rotate-telegraf -n iot
# Expected: emqx-rotate-telegraf   0 3 * * *   ...
```

- [ ] **Step 4: Trigger a manual test run and verify the password was rotated**

```bash
# Manually trigger the CronJob
kubectl create job --from=cronjob/emqx-rotate-telegraf emqx-rotate-test -n iot

# Watch the job logs
kubectl logs -f -l job-name=emqx-rotate-test -n iot
# Expected last line: MQTT credentials for 'telegraf' rotated and written to OpenBao.

# Clean up test job
kubectl delete job emqx-rotate-test -n iot
```

---

### Task 6: Verify end-to-end rotation propagation

After at least one rotation CronJob has run (or manual test from Task 4/5):

- [ ] **Step 1: Wait for ESO to pick up the change (max 5m)**

```bash
export KUBECONFIG=iac/clusters/server2/credentials/kubeconfig

# Watch ExternalSecret sync status
kubectl get externalsecret telegraf-influxdb2-credentials -n telegraf -w
# Look for: READY=True and lastSyncTime to update
```

- [ ] **Step 2: Verify Telegraf pod was restarted by Reloader**

```bash
kubectl get pods -n telegraf
# Look for a recently-started pod (AGE should be < 5m after the rotation)

# Check Reloader logs to confirm it triggered the restart
kubectl logs -l app=reloader -n reloader --tail=20
# Expected: Reloader noticed Secret change and restarted telegraf Deployment
```

- [ ] **Step 3: Verify Telegraf is writing metrics successfully after restart**

```bash
# Check Telegraf pod logs for successful InfluxDB2 writes
kubectl logs -l app.kubernetes.io/name=telegraf -n telegraf --tail=30 | grep -i "influx\|error"
# Expected: no write errors; "wrote batch" messages
```

---

### Task 7: Update docs

**Files:**
- Modify: `docs/architecture.md` — add Reloader row
- Modify: `docs/provisioning.md` — update rotation note
- Modify: `AGENTS.md` — layout tree updates

- [ ] **Step 1: Add Reloader row to architecture.md technology stack table**

Add after the External Secrets Operator row:

```markdown
| [Reloader](https://github.com/stakater/Reloader) | Watch Secrets/ConfigMaps; trigger rolling restart of annotated Deployments on change | server3 · server2 | ArgoCD `infra` | [reloader](https://artifacthub.io/packages/helm/stakater/reloader) | [shared](../gitops/helm-values/reloader.yaml) | [values.yaml](https://github.com/stakater/Reloader/blob/master/deployments/kubernetes/chart/reloader/values.yaml) |
```

- [ ] **Step 2: Update provisioning.md rotation note**

Replace the paragraph:
```
> **Rotation:** Scheduled credential rotation is not yet implemented. See [`docs/rotation-spec.md`](rotation-spec.md) for the planned approach.
```

With:
```
> **Rotation:** Scheduled rotation is implemented via CronJobs in each datastore's manifest directory (`CronJob.rotate.yaml`). Reloader watches the Telegraf ExternalSecrets and triggers a rolling restart when ESO updates the Secret after rotation.
```

- [ ] **Step 3: Update AGENTS.md layout tree**

Add `Reloader.yaml` to `apps/infra/` in the layout tree:
```
      infra/       ESO (AppSet, list generator), Reloader (AppSet, list generator)
```

Add `reloader.yaml` to the shared `gitops/helm-values/` section.

Add `CronJob.rotate.yaml` to `server2/influxdb2/` and `server2/emqx/` in the `k8s-manifests/server2/` section.

- [ ] **Step 4: Commit docs**

```bash
git add docs/architecture.md docs/provisioning.md AGENTS.md
git commit -m "docs: update architecture + provisioning docs for Reloader and rotation CronJobs"
```
