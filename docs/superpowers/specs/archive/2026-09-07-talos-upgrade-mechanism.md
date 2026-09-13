# Talos upgrades — the module cannot perform one, and trying would be destructive

**Status: CLOSED 2026-09-12.** Every defect below is fixed in code and applied, and the ordered path
below ran to completion. All three clusters are on **Talos v1.13.10 / Kubernetes v1.36.4**, healthy,
with Terraform drift-free. The SSD that this spec was paused on was installed 2026-09-12 and Longhorn
migrated onto it (see [the SATA migration runbook](../plans/2026-09-12-server3-longhorn-sata-migration.md)).

Keep this spec for the mechanism, which has not changed: **the module cannot perform an OS upgrade,
`talosctl upgrade --preserve` does, and Terraform runs afterwards only to reconcile state.** The three
provider defects it documents are still latent in `v0.11.0-beta.2` and the workarounds are still load-
bearing — `talos_secrets_contract` must stay frozen, and `install_wipe` must stay false.

Two claims below are now superseded by measurement and are marked in place: the v1.12.12 factory
availability note, and the "wait for the SSD" table. The MongoDB image-cache hazard was **not**
triggered on any of the six upgrades — `--preserve` keeps EPHEMERAL and therefore the containerd image
store, so mongod is still 8.2.7. That is now confirmed three times and is the single most useful thing
in this spec.

The 1.14 / 1.37 step was **deliberately postponed** — see
[Wave 4 step 4.3](../plans/2026-09-03-upgrade-w4-talos-kubernetes.md), which now carries the reasons.
Reaching 1.36 also left Cilium v1.19.2 and Longhorn v1.11.1 outside their upstream tested Kubernetes
matrices; that is Wave 3's problem now, not this spec's.

This spec owns the ordered path. The backup half is
[2026-09-07-longhorn-backup-target.md](2026-09-07-longhorn-backup-target.md), whose decision is
**offsite logical dumps (~300 MB), not a Longhorn backup target** — MinIO was proposed and dropped.
It also blocks [Wave 4](../plans/2026-09-03-upgrade-w4-talos-kubernetes.md).

**Trigger:** an attempt to run Wave 4 step 4.1 (Talos patch `v1.12.6` -> `v1.12.11`) on 2026-09-06.
Preflight passed; `terraform plan` was reviewed before applying and stopped the work. The bump was
reverted, nothing was applied.

**Parent:** [Wave 4 plan](../plans/2026-09-03-upgrade-w4-talos-kubernetes.md), whose step 4.1–4.3
procedure ("bump `talos_version`, `terraform plan && terraform apply`") is the thing this spec
contradicts.

---

## What is true today

```hcl
# iac/modules/bootstrap/main.tf
locals {
  installer_image = "factory.talos.dev/metal-installer/${var.talos_schematic_id}:${var.talos_version}"
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version          # <-- same variable
}

data "talos_machine_configuration" "controlplane" {
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  # talos_version NOT set                     # <-- provider default applies
  config_patches = [ ... machine.install = { image = local.installer_image, wipe = true } ... ]
}
```

One variable, `var.talos_version`, feeds two things that should not move together, and a third
consumer that should be set but is not.

## Three defects, in order of severity

### 1. `machine.install.wipe = true` is honoured on upgrade, not just install

Set for controlplane ([main.tf:46](../../../iac/modules/bootstrap/main.tf)) and worker (line 92).

Talos documents `.machine.install` as **"configuration is only applied during install/upgrade"** —
so this is not dormant-until-reinstall as one might assume from the field name.

**Corrected 2026-09-07 — the blast radius is not uniform.** An earlier draft of this spec said
"Longhorn's data lives on the same disk this instructs the installer to wipe". That is true on
server3 only:

| node | install disk (`install_disk_selector`) | Longhorn data |
|---|---|---|
| server1 | nvme `eui.ace42e81750c78a0` | dedicated SATA SSD `wwn-0x500a0751265f9efe` — **survives** |
| server2 | nvme `eui.ace42e8170382260` | dedicated SATA SSD `wwn-0x50026b725b05e218` — **survives** |
| server3 | nvme `eui.0025388391b1e82e` | **no `longhorn_disks` entry** — `/var/lib/longhorn` is on the install disk |

server3 is the cluster carrying ArgoCD, OpenBao, Grafana, Prometheus, Loki, Tempo and Authentik's
PostgreSQL, it has no dedicated disk, and it is a single control-plane node. It is the worst case
on every axis.

This does not make server1 and server2 safe: a wipe still takes STATE and EPHEMERAL — etcd, the
machine identity, the image cache — on all three. Only the Longhorn *replica data* differs.

**Unresolved, and must be established before any install path runs:** how `machine.install.wipe`
interacts with `talosctl upgrade --preserve`. Do not determine this empirically on a live node.

**This is dangerous independently of any upgrade work**: it fires whenever the install path is
exercised at all, including a node replacement or recovery.

### 2. The module cannot upgrade a running node

`installer_image` appears in exactly one place: `machine.install.image` inside a config patch. That
is a machine-config field. Applying a machine config does not ask a running node to reinstall — it
changes what a **future** install would use. There is no `talosctl upgrade` invocation, no upgrade
resource, no `null_resource` driving one.

So the Wave 4 procedure would have produced churn and no upgrade, while the plan's verification step
(`talosctl version` shows the target) would have failed with no obvious cause.

The supported mechanism is out-of-band:

```sh
talosctl upgrade --nodes <ip> --image factory.talos.dev/metal-installer/<schematic>:<version>
```

### 3. Bumping `talos_version` churns the cluster PKI

`talos_machine_secrets.talos_version` is, per the provider docs, the **version contract for secret
generation** — which secrets and config features to emit. It is not "the Talos version to run". The
provider's own guidance is to omit it or pin it explicitly; its tests use `major.minor`.

Wiring it to the same variable as the installer image means every OS upgrade rewrites the input to
the cluster's PKI resource. The measured plan for `v1.12.6 -> v1.12.11` on server2:

```
Plan: 2 to add, 3 to change, 2 to destroy.
  module.bootstrap.local_sensitive_file.talosconfig                   must be replaced
  module.bootstrap.talos_machine_configuration_apply.controlplane[0]  will be replaced
  module.bootstrap.talos_machine_secrets.this                         will be updated in-place
```

with `etcd`, `k8s`, `k8s_aggregator`, `os` CAs, `cluster.id`, `cluster.secret`, `bootstrap_token`
and `trustdinfo.token` all going `-> (known after apply)`.

**Read the provider source rather than testing this on a live cluster. It is worse than
"regenerates": the values are dropped.** Confirmed against the exact pinned version,
`v0.11.0-beta.2`, in `pkg/talos/talos_machine_secrets_resource.go`:

- `Update()` reads `talos_version` from the plan, writes it back to state, and then — as a wholly
  separate concern — regenerates only the **client certificate**, and only when it expires within a
  month. **It never writes `machine_secrets` back at all** (zero `SetAttribute` calls against that
  path).
- `ModifyPlan()` likewise only marks `client_configuration` attributes unknown, and only on that
  same expiry condition. It does not touch `machine_secrets`.
- `UseStateForUnknown` appears **exactly once in the entire file**, on the cluster `id`. None of the
  four CAs, the cluster secret, the bootstrap token or the trustd token carry it.

That combination is the bug. Without `UseStateForUnknown`, Terraform marks every one of those
computed attributes unknown on any update — which is exactly the `-> (known after apply)` seen in
the plan — and the provider then never supplies a value. The best case is a hard
"provider produced inconsistent result after apply" mid-apply, leaving state torn; the worse case is
the secrets landing null and `data.talos_machine_configuration` — which consumes
`talos_machine_secrets.this.machine_secrets` — generating a machine config from nothing, which
`talos_machine_configuration_apply.controlplane[0]` (already planned for **replacement**) then
applies to the live node.

`local_sensitive_file.talosconfig` being planned for replacement is consistent with the same cause:
its content derives from `client_configuration`.

**So this is not a risk to be weighed, it is a defect to be avoided.** Never let `var.talos_version`
reach `talos_machine_secrets`.

`talos_version` has **never been changed since bootstrap** (one commit, `064a6d8`; state records
`talos_version = "v1.12.6"`, CAs issued 2026-04-19). So there is no prior successful application of
this path to reason from.

## Proposed direction

**Separate the two concerns that share one variable.**

- `talos_secrets_contract` — frozen at the value the cluster was created with (`v1.12.6`, or the
  `v1.12` major.minor form the provider's tests use). Feeds `talos_machine_secrets` **only**. Never
  changes during an upgrade. Add `lifecycle { ignore_changes = [talos_version] }` on that resource
  as a second line of defence, so a future edit cannot silently churn the PKI.
- `talos_version` — the target OS version. Feeds `local.installer_image`, and should **also** be
  passed to `data.talos_machine_configuration.talos_version`, which the module does not set today.
  The provider explicitly warns that omitting it "can lead to unexpected behaviour when upgrading
  the provider, as new major versions of the Talos SDK may automatically enable new machine
  configuration features by default" — a latent config-drift source unrelated to this work.

  **This is not latent, it has already happened.** server2's state records
  `data.talos_machine_configuration.controlplane[0].talos_version = "v1.13"` while
  `talos_machine_secrets.this.talos_version = "v1.12.6"` and the node runs v1.12.6. The provider
  default won, unpinned and unnoticed: machine configs are being generated against v1.13 semantics
  for a v1.12.6 cluster. Pinning this is worth doing on its own, before any upgrade.

**Resolve `machine.install.wipe` before any install path runs.** Establish what it does on upgrade
in this configuration and whether it can be `false` without breaking bootstrap. If it must stay
`true` for clean installs, it needs to be conditional on a variable that is false during upgrades.

**Perform upgrades with `talosctl upgrade`**, then reconcile Terraform so state and reality agree
without the machine-secrets churn. With the split above, updating `talos_version` afterwards should
touch only the installer image in the machine config.

**Note the provider is `0.11.0-beta.2`** ([versions.tf:7](../../../iac/modules/bootstrap/versions.tf))
— a beta pinned across all three clusters. Worth reviewing as part of this, since the behaviour in
question is the provider's.

## Blocker discovered 2026-09-07: the Longhorn mountpoint is hardcoded

The module mounts a dedicated Longhorn disk at a fixed path:

```hcl
partitions = [{ mountpoint = "/var/lib/longhorn" }]
```

On server1 and server2 that was fine — their SATA SSDs were empty at bootstrap. **On server3,
`/var/lib/longhorn` already holds live replica data on the install nvme.** Adding
`longhorn_disks = { "192.168.1.202" = ... }` as the module stands would mount the new SSD *over*
that path, hiding the existing data rather than migrating it.

The module needs a per-node mountpoint so server3's SSD lands somewhere like `/var/mnt/longhorn-ssd`
and is added as a **second** Longhorn disk, with replicas evicted onto it while volumes stay online.
Verify Talos's current requirements for user volume mount paths while doing this.

## Ordered path

### Now — no hardware, no downtime

1. ~~**Module fix A — split the variable.**~~ **DONE 2026-09-07, commit `06591f3`.** `talos_secrets_contract` (frozen `v1.12.6`) feeding
   `talos_machine_secrets` only, plus `lifecycle { ignore_changes = [talos_version] }`. Values are
   unchanged, so `terraform plan` must come back with **zero changes** — that is simultaneously the
   fix and its proof, and it permanently defuses the PKI defect. Do **not** bundle step 8 into this.
2. ~~**Module fix B — per-node Longhorn mountpoint.**~~ **DONE 2026-09-07, commit `06591f3`.**
   No-op plan on all three; a wire test with a custom mountpoint planned exactly one in-place
   machine-config update and left the secrets alone.
3. ~~**Offsite dumps.**~~ **DONE 2026-09-07.** etcd ×3, Authentik Postgres, MongoDB ×2,
   InfluxDB2 ×2 and the OpenBao raft snapshot go to Cloudflare R2, driven by
   `~/homelab-backups/dump-all.sh`. Verified by downloading back from R2: sha256 match, and
   `mongorestore --dryRun` against the downloaded copy found every collection.

### Hardware window

4. Graceful shutdown of server3, install the SSD, boot, read `/dev/disk/by-id/...`.
5. `terraform apply` on server3 `bootstrap` with the disk at the non-conflicting mountpoint. Review
   the plan closely — first apply through this module since the drift was found.

### Online migration

6. Add the disk to `node.longhorn.io`, set `evictionRequested` on the default disk, let replicas
   rebuild onto the SSD. ~7 G of real data; volumes stay online.
7. Disable the default disk so nothing schedules back onto the install nvme.

### Only then

8. ~~Pin `data.talos_machine_configuration.talos_version` v1.13 -> v1.12.6.~~
   **DONE 2026-09-07, commit `5b8b2e2`.** The feared "genuinely changes generated config" turned
   out to be one added key, an empty `machine.network: {}` — established by generating both
   variants side by side in a throwaway module with the real `machine_secrets`, then confirmed by
   `talosctl apply-config --dry-run`. No reboot. Applied to all three.
9. ~~Make `machine.install.wipe` conditional.~~ **DONE 2026-09-07, commit `38d34f3`.**
   Now `var.install_wipe`, default false. All three nodes were live with `wipe: true`; they are
   now `false`. `talosctl patch --dry-run` confirmed no reboot, and uptimes are unchanged at
   127/141/141 days, so nothing restarted. **Defect 1 is resolved.**
10. ~~`talosctl upgrade --preserve` to **v1.12.12**~~ **DONE 2026-09-12, commit `cbd9038`** — all
    three clusters. Then carried straight on to v1.13.10 and Kubernetes 1.36.4; see Wave 4 steps 4.1
    and 4.2. Order used was server2 -> server1 -> server3, for the reason given here.

**Optional, if paranoia is cheap:** reproduce steps 1 and 8 against a throwaway `talosctl cluster
create` before touching server3, and confirm the plan touches only the installer image.

~~Read the provider source~~ — **done 2026-09-07, see defect 3.** The provider drops the secrets on
update; no cluster test was needed to reject that path.

## What is actually blocked now — reassessed 2026-09-07 after steps 8 and 9

**The SSD is no longer a prerequisite. It is risk reduction.** The reason server3 had to wait was
`machine.install.wipe = true`, which would have taken `/var/lib/longhorn` on the one node with no
dedicated disk. That is fixed and applied — all three nodes are now `wipe: false`.

| node | blocked? | why |
|---|---|---|
| server2 | **no** | dedicated Longhorn SSD, `wipe: false`, dumps offsite. Lightest node — upgrade here first |
| server1 | **no** | same, plus it carries the Loxone/EMQX path, so upgrade it after server2 |
| server3 | **not blocked, but wait anyway** | single disk holds OS *and* Longhorn. `--preserve` should keep it, but the SSD removes the failure mode entirely and costs only time |

**Caveat for server1 and server2 only:** their reboot may drop the image cache holding
`bitnami/mongodb` at 8.2.7, moving it to 8.3.8 and rewriting data files. That is the accepted
decision (see Wave 2 step 2.4 — **do not re-propose a digest pin**). Mitigation is procedural: run
`~/homelab-backups/dump-all.sh` immediately before each upgrade. server3 is unaffected — no
MongoDB, and all 56 of its image tags are pinned.

## Independent of the SSD, and worth doing

- **Longhorn filesystem trim.** ~23 Gi of blocks held for ~7.2 G of live data.
- **Provisioner tokens expire 2026-10-08** — see
  [provisioner token lifecycle](2026-09-06-provisioner-token-lifecycle.md). A dated future outage,
  not a current one.
- **Postgres superuser password mismatch** on `authentik-postgresql`. Needs a maintenance restart
  with `trust` auth, so bundle it with server3's SSD shutdown rather than doing it on its own.
- **Kubernetes 1.35.2 -> 1.37.0** stays a non-goal here. Separate mechanism, separate spec, and it
  must not be combined with an OS upgrade.

## Preflight already done, reusable if picked up soon

From 2026-09-06, all green: `talosctl` client v1.14.0 (ahead of target); schematic `613e1592...`
valid and carrying `iscsi-tools` + `util-linux-tools`; install disk selectors all still matching;
all three clusters `talosctl health` clean; **etcd snapshots** at
`/tmp/w4-snapshots/etcd-server{1,2,3}-2026-09-06.snapshot` (23/22/28 MB, hashes and revisions
recorded); **mongodumps** at `/tmp/w4-snapshots/mongo/server{1,2}-pre-w4.archive`.

**Measured 2026-09-06:** the installer image for `v1.12.12` did **not** resolve for this schematic
(released 2026-09-04, not built), while `v1.12.11`, `v1.13.10` and `v1.14.0` returned 200. Target
was set to `v1.12.11` on that basis.

**Re-measured 2026-09-07 — `v1.12.12` now returns 200.** The factory has since built it, so the
target should be **`v1.12.12`**, the newest 1.12 patch. `v1.12.13` and `v1.12.14` are 404 (not
released). The 2026-09-06 note stands as the general lesson — the newest patch is not always built
on the factory — but its specific conclusion is superseded. **Re-check availability at upgrade time
rather than trusting a recorded target.**

## Related hazards that fire on any node reboot

- **MongoDB runs `bitnami/mongodb:latest`** with `pullPolicy: IfNotPresent`, on **server1 and
  server2 only**. The node's cached layer is the only thing holding mongod at 8.2.7; `latest` is
  already 8.3.8. Any reboot that loses the image cache moves the engine across a release boundary
  and rewrites the data files, irreversibly, at FCV 8.2. Take a fresh dump immediately before each
  reboot, or pin the digest. See
  [Wave 2 step 2.4](../plans/2026-09-03-upgrade-w2-charts-medium-risk.md).
- **server3 is clear of this** — audited 2026-09-07, 56 distinct images, **every tag pinned**, no
  `latest`/`main`/`stable`. The SSD installation reboot is safe from the image-cache hazard.
- **A shell alias on the operator's machine** maps `tar` to
  `talosctl reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false --reboot`.
  Talos documents that exact command as the way to reset a machine into maintenance mode. Unrelated
  to this module, but it is the same destructive path reachable by a typo.

## Non-goals

- The Kubernetes upgrade (`1.35.2` -> `1.37.0`). Separate mechanism (`talosctl upgrade-k8s`),
  separate spec, and it should not be combined with an OS upgrade.
- Talos 1.14's `KubeNetworkConfig` multi-document migration, which the Wave 4 plan already defers.
