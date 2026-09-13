# Backups — logical dumps offsite, not a Longhorn backup target

**Status: BUILT AND IN USE — closed 2026-09-13.** The pause below (waiting on an SSD for server3)
ended on 2026-09-12 when the disk was installed. `~/homelab-backups/dump-all.sh` has been run
repeatedly since and is the safety net every irreversible step of the 2026-09-12/13 upgrade program
relied on — Longhorn 1.12.1, Kubernetes 1.36.4 and the Talos 1.13.10 rollout each took a verified
dump first.

**What it covers, and what it does not** — the exclusions matter more than the inclusions when
someone is planning a restore. Covered: etcd on all three clusters, the Authentik Postgres, MongoDB
x2, InfluxDB x2, and an OpenBao raft snapshot, checksummed under `SHA256SUMS` and verified on
Cloudflare R2 with `rclone check --checksum` (~300 MB). **Not covered:** Prometheus, Loki, Tempo,
Grafana, EMQX. See [docs/architecture.md](../../architecture.md) for the per-cluster table and
[AGENTS.md](../../../AGENTS.md) for how to run it.

**Two operational facts learned in use:**
- **Nothing schedules it.** It is run by hand, so its freshness is only as good as the last run.
- **The OpenBao raft snapshot only works while OpenBao is unsealed**, which makes the dump a
  *pre*-reboot step for server3, never a post-reboot one.

**Supersedes the MinIO plan.** An earlier version of this spec proposed MinIO on the server2
cluster as the Longhorn `backupTarget`. That is **dropped** — see "Why not MinIO" below. Nothing was
built, so there is nothing to unwind. Do not re-propose it.

**This is still not a Longhorn backup.** `backupTarget` remains `""`, there are no RecurringJobs or
Snapshots, and the CSI snapshotter is not installed — so there is no point-in-time volume restore.
These are application-level dumps: a rebuild path, not high availability.

**Why this existed:** Wave 4 and [the Talos upgrade spec](2026-09-07-talos-upgrade-mechanism.md) were
both blocked on "there are no backups". This removed that block, and turned out much cheaper than
first estimated. Both have since completed.

---

## The measurement that decided everything

Longhorn's `actualSize` counts blocks ever written, not live data. Measured 2026-09-07 against the
running filesystems:

| volume | Longhorn `actualSize` | actual filesystem | class |
|---|---|---|---|
| prometheus (server3) | 19.06 Gi | **6.2 G** (32% of vol) | replaceable |
| loki (server3) | 5.20 Gi | distroless, no `df` | replaceable |
| tempo (server3) | 1.23 Gi | distroless, no `df` | replaceable |
| mongodb (server1) | 1.24 Gi | **448 M** | important |
| mongodb (server2) | 1.12 Gi | **460 M** | important |
| influxdb2 (server1) | 0.62 Gi | **9.7 M** | important |
| influxdb2 (server2) | 0.53 Gi | **760 K** | important |
| grafana (server3) | 0.44 Gi | distroless, no `df` | important |
| authentik-postgresql (server3) | 0.33 Gi | **104 M** | **critical** |
| openbao (server3) | 0.25 Gi | **27.5 M** | **critical** |
| emqx ×2 | 0.04 Gi | — | trivial |

**155 Gi provisioned. 30 Gi by `actualSize`. ~7.2 G of real data where it could be measured** —
roughly 3× inflation, consistent with TSDB and WAL churn leaving blocks Longhorn has not reclaimed.

**The entire critical + important tier — OpenBao, Authentik PG, both MongoDB, both InfluxDB2 — is
~1.05 GB live.** Compressed dumps land in the hundreds of megabytes.

At that size the whole "which cloud, what does it cost" question collapses. See the pricing table
below: every option is under $1/month, and the critical tier fits inside Cloudflare R2's permanent
free tier.

## Decision

**Two tiers. The offsite tier is logical dumps, not Longhorn block backups.**

### Tier 1 — offsite logical dumps (the part that matters)

| source | mechanism |
|---|---|
| OpenBao | `bao operator raft snapshot` |
| Authentik PostgreSQL | `pg_dump` |
| MongoDB ×2 | `mongodump` — **already exists**, used in the Wave 4 preflight |
| InfluxDB2 ×2 | `influx backup` |
| etcd ×3 | `talosctl etcd snapshot` — procedure already exercised 2026-09-06 |

**Decided and working 2026-09-07: Cloudflare R2**, bucket `backup`, one prefix per date. One
less vendor — Cloudflare is already in the stack for cert-manager's DNS-01 — and the whole set
sits inside R2's permanent 10 GB free tier.

Driven by `~/homelab-backups/dump-all.sh` (rclone, backend configured through `RCLONE_CONFIG_*`
env vars so the secret never reaches `rclone.conf`; credentials read from the repo's gitignored
`.env`). Not yet a CronJob — it is run by hand before a reboot, which is what it is for.

**Grafana is excluded** — fully provisioned, dashboards and datasources come from ConfigMaps
via the sidecar, so `grafana.db` holds nothing git does not already have.

**Prometheus, Loki and Tempo are excluded, deliberately.** They are ~90% of the bytes and the least
worth keeping — metrics, logs and traces. Losing them costs history, not the cluster. Backing them
up would saturate a home uplink to protect data nobody would restore.

### Tier 2 — local Longhorn snapshots

Longhorn snapshots on the node, for fast rollback of a volume-level mistake. No remote target, no
MinIO, no extra infrastructure.

## Why logical dumps beat a Longhorn backup target here

1. **A block backup needs a working Longhorn to restore.** If server3 is a crater and you are
   rebuilding, OpenBao is the trust anchor — no OpenBao, no ESO, nothing starts. A `pg_dump` or a
   raft snapshot restores onto anything: bare Postgres, a fresh cluster, no Longhorn required.
2. **It sidesteps Longhorn's S3 compatibility quirks entirely.** R2 has documented multipart
   failures with Longhorn (*"All non-trailing parts must have the same length"*), and there are open
   reports of successful backups not appearing in the UI on S3-compatible backends. You discover
   this during a restore, which is the worst possible time.
3. **~300 MB compressed vs ~30 GB of blocks.** Fits a free tier; uploads over a home link in
   seconds, not hours.

## Why not MinIO on server2 (the dropped plan)

It was proposed as a `backupTarget` on server2's dedicated SATA SSD (223.5 Gi, 217.3 Gi free —
still true, still idle). Dropped because:

- The operator's intent was **temporary — just enough to unblock the Talos upgrade.** A full ArgoCD
  app plus ESO secret plus HTTPRoute plus bucket is disproportionate to a one-shot need, and
  temporary infrastructure that works is never removed.
- Once real data sizes were measured, offsite became free. A local S3 endpoint solves the smaller
  half of the problem (fast bulk restore) while leaving the larger half (surviving loss of the node)
  to the thing that costs nothing anyway.
- It carried the asymmetry that server2 could not back itself up.

Not ruled out forever. If bulk Prometheus/Loki/Tempo restore ever becomes worth having, MinIO on
server2 is where it should live. It is not worth building now.

## Pricing, recorded so it is not re-researched

Verified 2026-09-07. Sized at ~35 GB stored (the pessimistic all-volumes case); the actual dump tier
is ~1 GB.

| | storage/mo @35 GB | full 30 Gi restore | free tier |
|---|---|---|---|
| Backblaze B2 | **$0.21** | $0 — free to 3× stored | — |
| Cloudflare R2 | $0.53 | **$0** — zero egress | 10 GB + 1M Class A ops |
| AWS S3 Standard | $0.81 | $0 — under 100 GB/mo free | — |
| S3 Glacier Instant | $0.14 | $0.90 retrieval | — |

Dump tier only (~6 GB with history): B2 $0.04/mo, **R2 free**, S3 $0.14/mo.

**Price is not a decision input at this scale.** Decide on operational fit.

## Second SSD for server3 — bought 2026-09-07, not yet installed

Purchased. It is **not a backup and must not be treated as one** — `replicaCount` is 1 everywhere,
so a second disk in the same node gives no redundancy against disk death or node death.

It is worth having for one specific reason: server3 is the only node where `/var/lib/longhorn` sits
on the install disk, and `machine.install.wipe = true` is defect 1 in
[the Talos spec](2026-09-07-talos-upgrade-mechanism.md). The SSD makes server3 match server1 and
server2, and directly de-risks the upgrade.

**Not for capacity.** server3 has 181 Gi free against ~7 G of live data.

Sequencing, the mountpoint conflict, and the online replica migration are all in the Talos spec,
which owns the ordered path.

## The backup token expires 2026-10-09 — same trap as the provisioner tokens

`BAO_TOKEN` in `.env` is a snapshot-only token (`policies: [default, snapshot]`, cannot list secrets
engines — verified). It was minted with `-period=768h`, and lookup confirms `period = 2764800`.

That is **exactly OpenBao's default `max_lease_ttl` of 768h**, the same silent clamp documented in
[provisioner token lifecycle](2026-09-06-provisioner-token-lifecycle.md): a longer `-period` is not
honoured, and nothing renews the token, so it dies ~32 days after minting. Minted 2026-09-07, so it
dies around **2026-10-09** — one day after the provisioner tokens.

It fails loudly rather than silently: the dump script checks the snapshot is non-empty and a valid
archive, and aborts if not. But it *will* fail. Whatever fixes the provisioner token lifecycle
should cover this token too — it is the same defect with a different consumer.

## Open questions
- Dump schedule and retention. Daily with ~14 days is more than enough at these sizes.
- Where the CronJob lives — server3 can reach server1 and server2, but a dump job per cluster is
  simpler than one job with three sets of credentials.
- **Longhorn is holding ~23 Gi of blocks for ~7.2 G of live data.** Filesystem trim should reclaim
  most of it. Unrelated to backups, cheap, worth doing on its own.

## Not doing

- MinIO, anywhere, for now.
- Longhorn `backupTarget` to cloud — the S3 compatibility risk buys nothing the dumps do not.
- CSI snapshotter / `VolumeSnapshot`.
- Backing up Prometheus, Loki or Tempo offsite.
