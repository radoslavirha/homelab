# Talos v1.14 and Kubernetes 1.37 — upgrade spec

**Status:** open, **not started**. Deferred by the user on 2026-09-12 and still gated on a patch
release (below). Written 2026-09-17 as a handover. **Analyse this first, write an execution plan from
it second, implement third.** Nothing here has been tried on 1.14.

It consolidates the archived Talos plans, which were deleted on 2026-09-17, and adds what the
Headlamp OIDC work found about the API server on the same day. The **mechanism** of an upgrade is
unchanged and is recorded in
[`archive/2026-09-07-talos-upgrade-mechanism.md`](archive/2026-09-07-talos-upgrade-mechanism.md).
Read that first. Two provider defects it describes are still latent, and the workarounds are still
load-bearing.

---

## Where the fleet is

| | server1 | server2 | server3 |
|---|---|---|---|
| Talos | v1.13.10 | v1.13.10 | v1.13.10 |
| Kubernetes | v1.36.4 | v1.36.4 | v1.36.4 |
| Role | IoT datastores + custom apps | platform only (canary) | ArgoCD hub, OpenBao, Authentik, observability |

- Every cluster has a **single control plane and zero workers**. Each upgrade is a full outage for that
  cluster, with no HA cushion.
- Terraform provider `siderolabs/talos` **0.11.0**, pinned exactly in `iac/modules/bootstrap/versions.tf`.
- Schematic `613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245`
  (`siderolabs/iscsi-tools` + `siderolabs/util-linux-tools`, both for Longhorn).
- **Since 2026-09-17, each kube-apiserver carries `--oidc-*` flags**, rendered by the bootstrap
  module's `apiserver_oidc` variable as `cluster.apiServer.extraArgs`. Headlamp logins depend on them.
  Runbook: `docs/identity.md` § Headlamp.
- **Since 2026-09-17, machine-config applies use `apply_mode = "staged_if_needing_reboot"`.** A change
  that needs a reboot is staged, not applied, and Terraform still reports success.

## Gates. Check all of these before doing anything else

- [ ] **Talos v1.14.1 or later exists.** Every upgrade here has landed on a *patched* release
      (v1.12.12, v1.13.10), because a `.0` on this fleet has no fallback.
      `curl -s https://api.github.com/repos/siderolabs/talos/releases | jq -r '[.[]|select(.prerelease==false)|.tag_name][:5]'`
- [ ] **The factory has built the installer for our schematic.** It does not always: v1.12.12 was a
      404 on 2026-09-06 and a 200 on 2026-09-07. Re-check at upgrade time, and never trust a
      recorded target.
- [ ] **Kubernetes patch, from upstream:** `curl -sL https://dl.k8s.io/release/stable-1.37.txt`.
      `talosctl upgrade-k8s` validates the Talos↔Kubernetes pairing itself and refuses an unsupported
      one. Let it.
- [ ] **Everything that talks to the API is tested against 1.37.** Re-check each against its
      upstream matrix; none of this has been done yet: Cilium 1.20.1, Longhorn 1.12.1, Traefik
      41.5.0 / Gateway API 1.6.2, ArgoCD, cert-manager, External Secrets, Reloader, Headlamp 0.45.0,
      k8s-monitoring / Alloy, and the Authentik chart. Nothing may leave its tested matrix, which is
      exactly what happened when 1.36 landed ahead of Cilium and Longhorn.
- [ ] **The Terraform provider supports generating 1.14 machine configs.** Check 0.11.0's release
      notes and whether a newer provider is needed. Re-read its secrets defects before changing the pin.

---

## Open questions. The analysing agent's actual job

### 1. `apiserver_oidc` vs. 1.14's handling of kube-apiserver config — the highest risk

What was seen on 2026-09-17, as quick probes rather than an analysis. Treat it as a lead:

- The **v1.13.10** schema accepts `cluster.apiServer.extraArgs` with the `oidc-*` keys ("valid for
  metal mode") and **rejects** `cluster.apiServer.authenticationConfig` as an unknown key.
- A **v1.14.0** `talosctl`, validating a config that *it* had generated with that same extraArgs
  patch, failed with **`kube-apiserver config is already set in v1alpha1 config (.cluster.apiServer)`**.
  The 1.14.0 v1alpha1 schema also rejected `authenticationConfig`.

The likely reading is that 1.14 moves kube-apiserver configuration into its own document, which
conflicts with setting it in v1alpha1. If that's right:

- Bumping `talos_version` may make `data.talos_machine_configuration` emit the new document, and the
  module's v1alpha1 extraArgs patch would then **fail validation or be dropped**. Either breaks
  Headlamp logins, and the first could fail the apply outright.
- A 1.13-generated config applied to a 1.14 node may behave differently from a 1.14-generated one.

Establish, **offline**, before anything touches a cluster:

- the 1.14 document type and fields for kube-apiserver config, and specifically authentication
- what the provider renders at `talos_version = v1.14.x`, with and without `apiserver_oidc`
- whether the module needs a version-conditional patch, and in what order to land it relative to the OS
  upgrade

**The technique that worked for 1.13:** generate the old and the new machine config side by side,
from the cluster's *real* `machine_secrets`, in a throwaway module. First validate that the old-version
reconstruction is byte-identical to the live document, then diff. For 1.12.12 → 1.13.10 the whole
difference was two lines. Use pinned `talosctl` binaries for each version: the local client is v1.14.0
and gives the wrong answer for 1.13 questions.

**The opportunity:** if 1.14 supports structured `AuthenticationConfiguration` (several issuers, CEL
claim mappings), migrating `apiserver_oidc` to it is worth doing — **as its own change after the fleet
is settled**, the same rule as `KubeNetworkConfig` below.

### 2. `KubeNetworkConfig`

`.cluster.network` is deprecated in v1alpha1 in 1.14, not removed.
`iac/modules/bootstrap/patches/cilium.yaml` sets `cluster.network.cni.name: none` and
`cluster.proxy.disabled: true`. Upgrade first, then migrate **as a separate commit**. **JSON6902
patches are rejected on multi-document configs; use strategic-merge YAML.** Hit before; don't
rediscover it.

### 3. Smaller 1.14 changes with a fingerprint here

- **etcd metrics and the HTTP health endpoint leave `:2379`.** `gitops/helm-values/prometheus.yaml`
  already drops `etcd_*`, but confirm nothing scrapes 2379: `grep -rn 2379 gitops/`.
- **`machine.features.kubernetesTalosAPIAccess` is deprecated** in favour of a
  `KubeTalosAPIAccessConfig` document. Check whether any cluster sets it.
- **Kubernetes FlexVolume mounts are dropped** (`/usr/libexec/kubernetes`). Longhorn uses its own CSI
  driver, so this should be harmless. Verify it rather than assume.
- **Workload isolation**: default-on for *new* clusters only. **Leave it off.** With it enabled the
  deprecated in-tree iSCSI plugin stops working, and the schematic ships `iscsi-tools` for Longhorn.
- **`FilesystemTrimConfig`**: default for new clusters, absent on upgraded ones. It is optional, and
  would also cover the outstanding Longhorn trim on server3's SSD.

### 4. The post-upgrade Terraform apply

`talosctl upgrade` is out of band, so `apply_mode` doesn't affect it. It **does** affect the Terraform
apply that follows. If the regenerated config differs in a field that needs a reboot, the apply
**stages** it and reports success. After every apply, compare the node's active config
(`talosctl get machineconfig -o yaml`) with what was intended.

---

## The mechanism. Do not change it

- **The OS upgrade is `talosctl upgrade --preserve`.** `terraform apply` doesn't upgrade anything: it
  rewrites `machine.install.image` for a *future* install.
- **Terraform runs afterwards**, to reconcile state. Its plan must come back clean.
- **Never change `talos_secrets_contract`.** The provider drops the cluster's CAs and tokens on
  update (`talos_machine_secrets`); `ignore_changes` is a second guard.
- **`install_wipe` stays false.** `machine.install` is honoured on upgrade, not only on install.
- **Kubernetes is a separate change, after the OS verifies.** Never bump `kubernetes_version` before
  `upgrade-k8s` has run: it would advertise a 1.37 kubelet ahead of the control plane. This was
  caught mid-flight once on server3.

## Procedure outline, per cluster, **server2 → server1 → server3**

```bash
~/homelab-backups/dump-all.sh          # must print Done: and exit 0 (fixed 2026-09-17)
talosctl --context <c> etcd snapshot etcd-<c>-pre-114.snapshot   # Kubernetes has no downgrade path
talosctl --context <c> upgrade --preserve \
  --image factory.talos.dev/metal-installer/<schematic>:<v1.14.x>
# verify (gate below); then bump talos_version in iac/clusters/<c>/bootstrap/main.tf,
# terraform apply, plan clean, active machineconfig matches
talosctl --context <c> upgrade-k8s --to 1.37.x
# verify; then bump kubernetes_version, terraform apply, plan clean
```

server3 goes last. It is the ArgoCD hub and ESO's path to OpenBao, and **its OS upgrade reboots it:
OpenBao comes back sealed and the user must be present with 3 of 5 unseal keys.**

## What the 1.13 / 1.36 run taught

- `--preserve` keeps EPHEMERAL, which holds the containerd image store. That is why
  `bitnami/mongodb:latest` stays on its cached 8.2.7 across reboots. Confirmed on all six upgrades.
  **Do not re-propose a digest pin; it was declined.**
- `upgrade-k8s` restarts static pods and the kubelet, not workloads, so no unseal is needed for the
  Kubernetes half.
- While the apiserver restarts under `upgrade-k8s`, manifest patches hit `connection refused` /
  `connection reset`. talosctl's retry loop absorbs them.
- With a newer client, `talosctl health` reports k8s-side checks as **SKIP**. That's benign; use kubectl
  for readiness.
- server3's `/var/mnt/longhorn-ssd` user volume survives an OS upgrade. Still verify the Longhorn `ssd`
  disk comes back `Ready`.
- CoreDNS rides along with `upgrade-k8s` (it went v1.13.2 → v1.14.7 last time).
- **`bootID` is the probe for "did this reboot?"**, not uptime or pod age.
- **The kube-apiserver mirror pod lies on Talos.** It kept an old UID, a days-old start time and no
  new flags long after a restart. Verify apiserver flags with
  `talosctl get staticpods kube-apiserver -o yaml`, and a restart by container ID from
  `talosctl containers -k`.

## Verification gate, per cluster, after each half

```bash
KC=iac/clusters/<c>/credentials/kubeconfig; TC=iac/clusters/<c>/credentials/talosconfig; IP=<node>
talosctl --talosconfig $TC -n $IP -e $IP health --wait-timeout 10m
talosctl --talosconfig $TC -n $IP -e $IP version            # server == target
kubectl --kubeconfig $KC get nodes -o wide                   # Ready, expected kubelet
kubectl --kubeconfig $KC get pods -A | grep -v -E 'Running|Completed'
cilium status --wait
kubectl --kubeconfig $KC -n longhorn-system get volumes.longhorn.io    # all healthy, attached
# apiserver OIDC survived: flags present, authenticator initialised, a real login in the audit log
talosctl --talosconfig $TC -n $IP -e $IP get staticpods kube-apiserver -o yaml | grep -- --oidc
talosctl --talosconfig $TC -n $IP -e $IP read /var/log/audit/kube/kube-apiserver.log | grep '"username":"oidc:'
```

Plus: all ArgoCD applications Synced and Healthy; ESO secrets actually refreshed (force-sync one and
check `refreshTime`, because the badge lags); telemetry still flowing; the forward-auth UIs still 302
to `auth.irha.cz`.

In zsh, spell the `talosctl` flags out on every call. Packing them into one variable passes a single
argument, and verification silently returns nothing.

## Rollback

| Failure | Recovery |
|---|---|
| Talos upgrade fails, node reachable | `talosctl upgrade` back to the previous installer image |
| Talos upgrade fails, node unreachable | Rebuild from the pinned schematic; restore etcd from the snapshot |
| Kubernetes upgrade fails | **No downgrade path.** Restore from the etcd snapshot |
| Workload broken by a removed API | Fix the chart values forward; do not downgrade |
| Headlamp logins break after the upgrade | Kubernetes access is unaffected: admin kubeconfigs don't use OIDC. Fix the apiserver config forward |

## Exit criteria

- All three clusters on Talos v1.14.x / Kubernetes 1.37.x, healthy, Terraform drift-free.
- Nothing outside its upstream tested matrix.
- Headlamp OIDC login verified in the audit log on each cluster.
- Afterwards, as **separate** commits: the `KubeNetworkConfig` migration, and, if the 1.14 analysis
  supports it, `apiserver_oidc` moved to structured authentication.
