# Automate the backup — a starting point, not a design

**Status:** OPEN, deliberately thin. Written 2026-09-22 to be analysed and refined by later agents.
The user's ask: *"I would prefer automated dump, maybe on Longhorn."* This document states what is
measured, what is already decided, and what is genuinely open. **It does not choose a mechanism.**

## The problem, in one line

`~/homelab-backups/dump-all.sh` works and is verified — and **nothing runs it.** It is invoked by
hand from the laptop. Last run: 2026-09-17. That is the whole gap.

## What is true today (measured 2026-09-22)

- **Zero automation of any kind.** No CronJobs on any cluster, no Longhorn `RecurringJob`, no
  Longhorn `backupTarget`, no VolumeSnapshots. The script is the only backup that exists.
- It covers: `talosctl etcd snapshot` ×3, Authentik `pg_dump`, `mongodump` (server1), OpenBao
  `bao operator raft snapshot`, `influx backup` (server1). Then SHA256SUMS, `rclone copy` to
  Cloudflare R2, and `rclone check` to verify the remote copy. Retention via `R2_KEEP_DAYS`.
- It runs from the laptop because it needs three kubeconfigs **and three talosconfigs** — the etcd
  snapshots go through the Talos API, not the Kubernetes API.
- Credentials live in `$REPO/.env` (chmod 600, gitignored): `R2_*` and `BAO_TOKEN`.
- **`BAO_TOKEN` expires ~2026-10-09** and is the one hard deadline in this area.

## Already decided — do not re-litigate without new evidence

**Longhorn block backups were evaluated and rejected on 2026-09-07.**
Spec: [`archive/2026-09-07-longhorn-backup-target.md`](archive/2026-09-07-longhorn-backup-target.md).
The reasoning, which still holds:

1. **A block backup needs a working Longhorn to restore. A logical dump restores onto anything.**
2. **OpenBao is the trust anchor** — no OpenBao, no ESO, nothing in the cluster starts. Its raft
   snapshot is the single most important artifact, and it is not a Longhorn volume concern.
3. **The critical tier is ~1.05 GB live**, so offsite dumps are effectively free. Longhorn's
   `actualSize` overstates live data ~3× (30 Gi reported vs ~7.2 G real), which makes block backup
   look far more necessary than it is.
4. Prometheus, Loki and Tempo are **deliberately excluded** — ~90% of the bytes, least worth
   restoring.

**MinIO on server2 as a `backupTarget` was proposed and dropped. Do not re-propose it.**

> **One thing genuinely changed since that decision, and a refining agent should weigh it:**
> the 2026-09-07 rejection was of *MinIO on server2* as the target. Longhorn can target an
> S3-compatible endpoint directly, and R2 already exists and is already paid for. That is a
> different proposal from the one that was dropped. It does **not** answer objections 1 and 2 —
> it only removes the "we would have to run MinIO" cost. Treat it as a narrower question:
> *is there any volume whose loss is not already covered by a logical dump?*
> As of 2026-09-22 the honest answer looks like "no", and the burden is on the proposal.

**Consequence already accepted:** the observability dashboard's "volumes with no backup" panel
reads 100% forever. That is correct, not a regression.

## The open question

**Where does the automation run, given it needs Talos API access?**

Nothing here is decided. Sketching the tension only:

- **In-cluster (CronJob).** Natural home for the `pg_dump`/`mongodump`/`influx backup`/OpenBao
  steps. But etcd snapshots need `talosctl` + a talosconfig, and a cross-cluster job needs
  credentials for clusters it does not live in. Splitting the script by "what needs Talos" may be
  the real design question.
- **On the laptop (launchd / cron).** Zero new credential surface, keeps the script as-is — but it
  only runs when the laptop is awake, which is a silent-failure mode. **Whatever runs it, a backup
  nobody is told failed is not a backup: alerting on "no successful run in N days" matters more
  than the schedule.** There is an alerting path now (`slack-irha-homelab`, verified 2026-09-21).

## Credentials — one constraint that is NOT negotiable

`BAO_TOKEN` can and should leave `.env`: the script already `kubectl exec`s into `openbao-0`, so it
can log in there with a projected ServiceAccount token. PR #9 (`5a4dc6b`, `f1e45a7`) did exactly this
for the provisioner and is the template. **This also removes the 2026-10-09 deadline permanently.**

`R2_*` **must stay outside OpenBao.** It is circular: OpenBao's snapshot lives in R2, so recovering
OpenBao requires R2 credentials first. Storing them in OpenBao makes the backup unrestorable in
precisely the disaster it exists for. If automation needs them in-cluster, they may be synced via
ESO **as well as** kept somewhere outside the cluster (password manager, or `.env`) — never only
inside.

## What a refining agent should produce

1. A decision on where the automation runs, with the Talos-API split addressed explicitly.
2. A failure-notification path (the backup that silently stops is the failure mode that matters).
3. The `BAO_TOKEN` → Kubernetes auth change, which is worth doing on its own regardless of the rest.
4. A restore rehearsal. **Nothing in this repo records a restore ever having been tested** — that is
   a bigger hole than the missing schedule, and no amount of automation closes it.
