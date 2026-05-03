# Data Migration from Old Server1

Migrate InfluxDB2 and MongoDB data from the old server1 Kubernetes cluster (Debian) to the new server1 Kubernetes cluster (Talos Linux).

**Source:** old server1 — Kubernetes on Debian, InfluxDB2 in `monitoring` namespace, MongoDB in `mongodb` namespace  
**Target:** new server1 — Kubernetes on Talos Linux, InfluxDB2 in `iot` namespace, MongoDB in `mongodb` namespace  
**Access:** `kubectl port-forward` on both ends — all commands run from your Mac

## Scope

| Service | Migrate | Skip |
|---------|---------|------|
| InfluxDB2 — bucket `loxone` | yes | — |
| InfluxDB2 — bucket `loxone_downsample` | yes | — |
| InfluxDB2 — tokens, users | **no** | provisioner creates these |
| MongoDB — `miot-bridge` data | yes | — |
| MongoDB — `miot-bridge-sandbox` data | yes | — |
| MongoDB — users, credentials | **no** | provisioner creates these |

> **Important:** The migration is split into two phases separated by the OS swap:
> - **Phase 1 (before wipe):** export data from the old cluster while it is still running
> - **Phase 2 (after new cluster is ready):** import into the new Talos cluster once ArgoCD + provisioner have completed

## Prerequisites

```bash
# Path to old kubeconfig (new cluster kubeconfig available after Talos bootstrap)
OLD_KC=~/.kube/old-server1-kubeconfig           # your old Debian k8s kubeconfig

# influx CLI — must match source InfluxDB2 version (2.7)
brew install influxdb-cli
influx version   # should show 2.7.x

# mongodump / mongorestore
brew install mongodb-database-tools
```

---

## Phase 1: Export from old cluster (before OS swap)

Do this while the old Debian cluster is still running. Keep the port-forwards open until all exports are done.

### Step 1: Retrieve old credentials

```bash
# InfluxDB2 admin token
kubectl --kubeconfig=$OLD_KC get secret -n monitoring influxdb2-auth -o jsonpath='{.data.admin-token}' | base64 -d

# MongoDB root password
kubectl --kubeconfig=$OLD_KC get secret -n mongodb mongodb -o jsonpath='{.data.mongodb-root-password}' | base64 -d
```

> Adjust secret names above if they differ in your old cluster.

### Step 2: Open source port-forwards

Run in separate terminal tabs:

```bash
# InfluxDB2 source — http://localhost:18086
kubectl --kubeconfig=$OLD_KC port-forward -n monitoring svc/influxdb2 18086:80

# MongoDB source — localhost:27018
kubectl --kubeconfig=$OLD_KC port-forward -n mongodb svc/mongodb 27018:27017
```

### Step 3: Backup InfluxDB2 buckets

```bash
OLD_INFLUX_TOKEN=<old-admin-token>

influx backup ./influx-backup-loxone \
  --host   http://localhost:18086 \
  --token  $OLD_INFLUX_TOKEN \
  --org    home-server \
  --bucket loxone

influx backup ./influx-backup-loxone-downsample \
  --host   http://localhost:18086 \
  --token  $OLD_INFLUX_TOKEN \
  --org    home-server \
  --bucket loxone_downsample
```

### Step 4: Dump MongoDB databases

```bash
OLD_MONGO_PASS=<old-mongodb-root-password>

mongodump \
  --host localhost:27018 \
  --username root \
  --password "$OLD_MONGO_PASS" \
  --authenticationDatabase admin \
  --db miot-bridge \
  --archive=miot-bridge.archive \
  --gzip

mongodump \
  --host localhost:27018 \
  --username root \
  --password "$OLD_MONGO_PASS" \
  --authenticationDatabase admin \
  --db miot-bridge-sandbox \
  --archive=miot-bridge-sandbox.archive \
  --gzip
```

Verify the files exist before proceeding:

```bash
ls -lh influx-backup-loxone/ influx-backup-loxone-downsample/ miot-bridge.archive miot-bridge-sandbox.archive
```

**Now you can wipe and reinstall the OS.**

---

## Phase 2: Import into new cluster (after Talos bootstrap)

Wait until:
1. Talos cluster is bootstrapped (`iac/clusters/server1/bootstrap` + `platform` applied)
2. ArgoCD IoT and Databases stages have synced
3. Provisioner Jobs have completed — they create the target buckets (`loxone`, `loxone_downsample`) and databases (`miot-bridge-production`, `miot-bridge-sandbox`)

```bash
NEW_KC=iac/clusters/server1/credentials/kubeconfig
```

### Step 5: Retrieve new credentials

```bash
# InfluxDB2 admin token
bao kv get secret/server1/influxdb2
# use value of field: admin-token

# MongoDB root password
bao kv get secret/server1/mongodb
# use value of field: mongodb-root-password
```

### Step 6: Open target port-forwards

```bash
# InfluxDB2 target — http://localhost:8086
kubectl --kubeconfig=$NEW_KC port-forward -n iot svc/influxdb2 8086:80

# MongoDB target — localhost:27017
kubectl --kubeconfig=$NEW_KC port-forward -n mongodb svc/mongodb 27017:27017
```

### Step 7: Restore InfluxDB2 buckets

```bash
NEW_INFLUX_TOKEN=<new-admin-token>

influx restore ./influx-backup-loxone \
  --host   http://localhost:8086 \
  --token  $NEW_INFLUX_TOKEN \
  --org    homelab \
  --org-id d18e0dd923d39236 \
  --bucket loxone

influx restore ./influx-backup-loxone-downsample \
  --host   http://localhost:8086 \
  --token  $NEW_INFLUX_TOKEN \
  --org    homelab \
  --org-id d18e0dd923d39236 \
  --bucket loxone_downsample
```

### Step 8: Restore MongoDB databases

```bash
MONGO_ROOT_PASS=<new-mongodb-root-password>

mongorestore \
  --host localhost:27017 \
  --username root \
  --password "$MONGO_ROOT_PASS" \
  --authenticationDatabase admin \
  --nsFrom "miot-bridge.*" \
  --nsTo   "miot-bridge-production.*" \
  --archive=miot-bridge.archive \
  --gzip

mongorestore \
  --host localhost:27017 \
  --username root \
  --password "$MONGO_ROOT_PASS" \
  --authenticationDatabase admin \
  --nsFrom "miot-bridge-sandbox.*" \
  --nsTo   "miot-bridge-sandbox.*" \
  --archive=miot-bridge-sandbox.archive \
  --gzip
```

> Add `--drop` only if you need to overwrite existing data (destructive).

---

## Step 9: Verify

### InfluxDB2

```bash
influx query \
  --host  http://localhost:8086 \
  --token $NEW_INFLUX_TOKEN \
  --org   homelab \
  'from(bucket: "loxone") |> range(start: -7d) |> count()'
```

### MongoDB

```bash
mongosh "mongodb://root:${MONGO_ROOT_PASS}@localhost:27017/admin"

use miot-bridge-production
db.stats()

use miot-bridge-sandbox
db.stats()
```

---

## Step 10: Cleanup

```bash
# Kill all port-forwards
pkill -f "kubectl port-forward"

# Remove local dump files
rm -rf influx-backup-loxone influx-backup-loxone-downsample
rm -f miot-bridge.archive miot-bridge-sandbox.archive
```
