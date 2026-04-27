# Data Migration from Old Server1

Migrate InfluxDB and MongoDB data from the old standalone Debian server1 to the new Kubernetes-managed services on server2.

**Source:** old server1 (Debian, SSH accessible)  
**Target:** server2 Kubernetes cluster — InfluxDB2 in `iot` namespace, MongoDB in `mongodb` namespace  
**Access to target:** `kubectl port-forward` (no SSH to Talos nodes)

## Scope

| Service | Migrate | Skip |
|---------|---------|------|
| InfluxDB — bucket `loxone` | yes | — |
| InfluxDB — bucket `loxone_downsample` | yes | — |
| InfluxDB — tokens, users | **no** | provisioner creates these |
| MongoDB — `miot-bridge` data | yes | — |
| MongoDB — `miot-bridge-sandbox` data | yes | — |
| MongoDB — users, credentials | **no** | provisioner creates these |

> **Prerequisite:** Run this migration **after** the IoT and Databases ArgoCD stages have synced and the provisioner Jobs have completed. The provisioner creates the target buckets (`loxone`, `loxone_downsample`) and target databases (`miot-bridge-production`, `miot-bridge-sandbox`) before data is imported.

---

## Prerequisites

Local machine needs:

```bash
# kubectl + kubeconfig for server2
export KUBECONFIG=iac/clusters/server2/credentials/kubeconfig

# influx CLI (for InfluxDB2 import)
# https://docs.influxdata.com/influxdb/v2/tools/influx-cli/

# mongodump / mongorestore
brew install mongodb-database-tools   # macOS
```

---

## Step 0: Check source versions

SSH into old server1 and check versions:

```bash
ssh old-server1

# InfluxDB version
influxd version
# or: influx version

# MongoDB version
mongod --version
```

> The steps below cover both InfluxDB **v1.x** and **v2.x** sources. Follow the section that matches.

---

## Step 1: Retrieve target credentials

Get the admin credentials from OpenBao before starting:

```bash
# InfluxDB2 admin token
bao kv get secret/server2/influxdb2
# use value of field: admin-token

# MongoDB root password
bao kv get secret/server2/mongodb
# use value of field: mongodb-root-password
```

---

## Step 2: Open port-forwards to target services

Run these in separate terminal tabs and keep them open throughout the migration:

```bash
# InfluxDB2 — http://localhost:8086
kubectl port-forward -n iot svc/influxdb2 8086:80

# MongoDB — localhost:27017
kubectl port-forward -n mongodb svc/mongodb 27017:27017
```

---

## Step 3: Migrate InfluxDB

### Verify target buckets exist

```bash
influx bucket list \
  --host http://localhost:8086 \
  --token <admin-token> \
  --org homelab
```

Both `loxone` and `loxone_downsample` must appear before continuing.

---

### If source is InfluxDB 1.x

#### 3a. Export line protocol from old server1

```bash
ssh old-server1

# Check data and WAL paths (adjust if non-default)
ls /var/lib/influxdb/data/
ls /var/lib/influxdb/wal/

# Export loxone database as line protocol
influx_inspect export \
  --datadir /var/lib/influxdb/data \
  --waldir  /var/lib/influxdb/wal \
  --database loxone \
  --out /tmp/loxone.lp

# Export loxone_downsample database
influx_inspect export \
  --datadir /var/lib/influxdb/data \
  --waldir  /var/lib/influxdb/wal \
  --database loxone_downsample \
  --out /tmp/loxone_downsample.lp
```

#### 3b. Strip export headers

`influx_inspect export` prepends `# DDL` / `# DML` comment lines that InfluxDB2 rejects. Strip them:

```bash
# On old server1 — create clean files
grep -v '^#' /tmp/loxone.lp            > /tmp/loxone_clean.lp
grep -v '^#' /tmp/loxone_downsample.lp > /tmp/loxone_downsample_clean.lp
```

#### 3c. Copy files to local machine

```bash
scp old-server1:/tmp/loxone_clean.lp            ./loxone.lp
scp old-server1:/tmp/loxone_downsample_clean.lp ./loxone_downsample.lp
```

#### 3d. Import into InfluxDB2 (via port-forward)

```bash
# Import loxone
influx write \
  --host  http://localhost:8086 \
  --org   homelab \
  --bucket loxone \
  --token <admin-token> \
  --format lp \
  --file  loxone.lp

# Import loxone_downsample
influx write \
  --host   http://localhost:8086 \
  --org    homelab \
  --bucket loxone_downsample \
  --token  <admin-token> \
  --format lp \
  --file   loxone_downsample.lp
```

> **Large datasets:** InfluxDB2 accepts a `--compression gzip` flag. If the export files are very large, compress them first and add `--compression gzip` to the import command.

---

### If source is InfluxDB 2.x

#### 3a. Backup on old server1

```bash
ssh old-server1

# Full backup (includes metadata + data)
influx backup /tmp/influx-backup \
  --host  http://localhost:8086 \
  --token <old-admin-token>
```

#### 3b. Copy backup to local machine

```bash
scp -r old-server1:/tmp/influx-backup ./influx-backup
```

#### 3c. Restore specific buckets (via port-forward)

Restore each bucket by name. The `--org` flag maps to the target org:

```bash
influx restore ./influx-backup \
  --host   http://localhost:8086 \
  --token  <admin-token> \
  --org    homelab \
  --bucket loxone

influx restore ./influx-backup \
  --host   http://localhost:8086 \
  --token  <admin-token> \
  --org    homelab \
  --bucket loxone_downsample
```

> If the source org name differs from `homelab`, add `--org-id <old-org-id>` to map it. Get the old org id with `influx org list` on old server1.

---

## Step 4: Migrate MongoDB

### Check old database/collection names

Before dumping, confirm the exact database and collection names on old server1:

```bash
ssh old-server1
mongosh  # or mongo if v4

show dbs
use <database-name>
show collections
```

Identify which database holds the `miot-bridge` collections. Likely candidates:

| Old structure | Target database on new server2 |
|---|---|
| database `miot-bridge`, any collections | `miot-bridge-production` |
| database `miot-bridge-sandbox`, any collections | `miot-bridge-sandbox` |

---

### 4a. Dump from old server1

Dump each database as an archive. Adjust `--username` / `--password` to the old server1 MongoDB admin credentials.

```bash
ssh old-server1

# Dump miot-bridge database
mongodump \
  --db miot-bridge \
  --archive=/tmp/miot-bridge.archive \
  --gzip

# Dump miot-bridge-sandbox database (if it exists as a separate database)
mongodump \
  --db miot-bridge-sandbox \
  --archive=/tmp/miot-bridge-sandbox.archive \
  --gzip
```

> If old server1 has auth enabled, add: `--username admin --password <password> --authenticationDatabase admin`

---

### 4b. Copy archives to local machine

```bash
scp old-server1:/tmp/miot-bridge.archive         ./miot-bridge.archive
scp old-server1:/tmp/miot-bridge-sandbox.archive  ./miot-bridge-sandbox.archive
```

---

### 4c. Restore into target databases (via port-forward)

The new database names on server2 are `miot-bridge-production` and `miot-bridge-sandbox`.  
Use `--nsFrom` / `--nsTo` to remap the namespace if the old database name differs.

```bash
MONGO_ROOT_PASS=<mongodb-root-password>

# Restore miot-bridge → miot-bridge-production
mongorestore \
  --host localhost:27017 \
  --username root \
  --password "$MONGO_ROOT_PASS" \
  --authenticationDatabase admin \
  --nsFrom "miot-bridge.*" \
  --nsTo   "miot-bridge-production.*" \
  --archive=miot-bridge.archive \
  --gzip

# Restore miot-bridge-sandbox → miot-bridge-sandbox
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

> If old and new db names are already the same you can omit `--nsFrom` / `--nsTo`.  
> Add `--drop` only if you need to replace existing data (destructive — ask before using).

---

## Step 5: Verify

### InfluxDB2

```bash
# Row counts per bucket (replace time range as needed)
influx query \
  --host  http://localhost:8086 \
  --token <admin-token> \
  --org   homelab \
  '
  import "influxdata/influxdb/schema"
  schema.measurements(bucket: "loxone")
  '

# Quick point count for a measurement
influx query \
  --host  http://localhost:8086 \
  --token <admin-token> \
  --org   homelab \
  '
  from(bucket: "loxone")
    |> range(start: -7d)
    |> count()
  '
```

### MongoDB

```bash
mongosh "mongodb://root:${MONGO_ROOT_PASS}@localhost:27017/admin"

use miot-bridge-production
db.stats()
show collections

use miot-bridge-sandbox
db.stats()
show collections
```

---

## Step 6: Cleanup

```bash
# Kill port-forwards
pkill -f "kubectl port-forward"

# Remove local dump files
rm -f loxone.lp loxone_downsample.lp miot-bridge.archive miot-bridge-sandbox.archive
rm -rf influx-backup

# Remove temp files on old server1
ssh old-server1 'rm -f /tmp/loxone*.lp /tmp/miot-bridge*.archive /tmp/influx-backup'
```
