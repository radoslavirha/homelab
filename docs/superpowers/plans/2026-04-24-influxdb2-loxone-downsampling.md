# InfluxDB2 Loxone Bucket + Downsampling Task Provisioning

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing InfluxDB2 PostSync provisioner on server2 to:
1. Also create a `loxone-downsample` bucket (alongside the existing `loxone` bucket creation).
2. Create a Flux downsampling task that reads raw data from `loxone`, and writes to `loxone-downsample`.

Already working value which we should set.
```
option task = {name: "Downsample Loxone", every: 10m}

from(bucket: "loxone")
    |> range(start: -task.every)
    |> aggregateWindow(every: task.every, fn: mean)
    |> to(bucket: "loxone_downsample")
```

**Context:** The provisioner at `gitops/k8s-manifests/server2/influxdb2/provisioner-telegraf.yaml` already creates the `loxone` bucket and a write-only Telegraf token. It runs as an ArgoCD PostSync Job (idempotent). The InfluxDB2 Tasks API (`/api/v2/tasks`) accepts a Flux script and manages scheduling server-side.

**Architecture:** Extend the single `provisioner-telegraf.yaml` Job to add bucket + task provisioning steps after the existing loxone bucket creation. Both additions are idempotent (check-then-create). The Flux task runs inside InfluxDB2 — no external scheduler needed.

---

## Steps

### 1. Extend `provisioner-telegraf.yaml` — add `loxone-downsample` bucket

- [ ] In `gitops/k8s-manifests/server2/influxdb2/provisioner-telegraf.yaml`, after the block that ensures the `loxone` bucket exists, add an identical idempotency block for `loxone-downsample`:

```sh
DOWNSAMPLE_BUCKET="loxone-downsample"

DOWNSAMPLE_BUCKET_ID=$(curl -sf \
  -H "Authorization: Token ${INFLUX_TOKEN}" \
  "${INFLUX_HOST}/api/v2/buckets?org=${ORG}&name=${DOWNSAMPLE_BUCKET}" \
  | jq -r '.buckets[0].id // empty')

if [ -z "$DOWNSAMPLE_BUCKET_ID" ]; then
  echo "Creating bucket '${DOWNSAMPLE_BUCKET}'..."
  DOWNSAMPLE_BUCKET_ID=$(curl -sf -X POST \
    -H "Authorization: Token ${INFLUX_TOKEN}" \
    -H "Content-Type: application/json" \
    "${INFLUX_HOST}/api/v2/buckets" \
    -d "{\"name\":\"${DOWNSAMPLE_BUCKET}\",\"orgID\":\"${ORG_ID}\",\"retentionRules\":[{\"type\":\"expire\",\"everySeconds\":7776000}]}" \
    | jq -r '.id')
  echo "Bucket '${DOWNSAMPLE_BUCKET}' created: ${DOWNSAMPLE_BUCKET_ID}"
fi
```

Retention for `loxone-downsample`: 90 days (`7776000` seconds) — raw `loxone` bucket has no retention (keep forever). Adjust if needed.

### 2. Extend `provisioner-telegraf.yaml` — add downsampling Flux task

- [ ] After both bucket creation blocks, add task provisioning. Check existence by task name, create if missing:

```sh
TASK_NAME="loxone-downsample-1m"

EXISTING_TASK_ID=$(curl -sf \
  -H "Authorization: Token ${INFLUX_TOKEN}" \
  "${INFLUX_HOST}/api/v2/tasks?org=${ORG}&name=${TASK_NAME}" \
  | jq -r '.tasks[0].id // empty')

if [ -n "${EXISTING_TASK_ID}" ]; then
  echo "Task '${TASK_NAME}' already exists (${EXISTING_TASK_ID}). Skipping."
else
  echo "Creating downsampling task '${TASK_NAME}'..."
  FLUX_SCRIPT=$(cat <<'FLUX'
option task = {name: "loxone-downsample-1m", every: 1m, offset: 10s}

from(bucket: "loxone")
  |> range(start: -task.every)
  |> filter(fn: (r) => r._measurement != "")
  |> aggregateWindow(every: 1m, fn: mean, createEmpty: false)
  |> to(bucket: "loxone-downsample", org: "homelab")
FLUX
)
  curl -sf -X POST \
    -H "Authorization: Token ${INFLUX_TOKEN}" \
    -H "Content-Type: application/json" \
    "${INFLUX_HOST}/api/v2/tasks" \
    -d "{\"org\":\"${ORG}\",\"flux\":$(echo "${FLUX_SCRIPT}" | jq -Rs .)}"
  echo "Task '${TASK_NAME}' created."
fi
```

**Flux task notes:**
- `every: 1m, offset: 10s` — runs 10s after each minute boundary to ensure data has landed.
- `aggregateWindow(fn: mean)` — suitable for sensor/numeric Loxone data. Change to `last` for state/enum fields if needed.
- `createEmpty: false` — suppresses null windows when no data arrives.
- Adjust `_measurement` filter if specific measurements should be excluded.

### 3. Update provisioner header comment

- [ ] Update the top-of-file comment block to reflect the new responsibilities:

```yaml
# InfluxDB2 PostSync provisioner: Loxone buckets + downsampling task + Telegraf write token
# Runs on every ArgoCD sync. On first deploy:
#   1. Ensures the "loxone" bucket exists
#   2. Ensures the "loxone-downsample" bucket exists (90-day retention)
#   3. Ensures the "loxone-downsample-1m" Flux downsampling task exists
#   4. Creates a write-only token scoped to the "loxone" bucket
#   5. Writes the token to OpenBao: secret/server2/telegraf-influxdb2
# On subsequent syncs: all resources already exist → skip (no-op).
```

### 4. Verify

- [ ] Force-sync the InfluxDB2 ArgoCD Application on server2 and watch the PostSync Job logs.
- [ ] Confirm `loxone-downsample` bucket appears in the InfluxDB2 UI.
- [ ] Confirm `loxone-downsample-1m` task appears under Tasks and has a recent run.
- [ ] After Loxone data arrives in `loxone`, query `loxone-downsample` to confirm aggregated points are written.

---

## Notes

- The `loxone-downsample` bucket retention (90 days) is a suggestion. Adjust `everySeconds` in the `retentionRules` payload before first deploy.
- If the Flux task needs to handle non-numeric fields differently (e.g., string state fields), split the task into two: one `mean` pass for numerics (filtered by `r._field != "state"`) and one `last` pass for strings.
- The Tasks API requires the full Flux `option task = {...}` header inline in the script — it cannot be passed separately.
