# EMQX storage expansion — spec

**Status:** proposed, not scheduled. Nothing here has been applied.
**Scope:** the size of the EMQX data volume on server1 and server2, and two values-file defects found alongside it. Enabling `emqx_prometheus` is a separate item (`4.2` in the dashboard plan) and is deliberately out of scope.
**Audience:** whoever picks this up next. Everything below was verified against the live clusters on 2026-08-14; re-verify before acting, the numbers move.

## How this surfaced

Not from an incident. The `Platform` Grafana dashboard's storage panel showed the EMQX volume at ~100%, which turned out to be Longhorn reporting *blocks allocated*, not *bytes used* — see [observability.md](observability.md#dashboards). Chasing that false alarm turned up the real finding: the volume is **20 MiB**, and nobody chose that number.

## Verified current state

| Fact | server1 | server2 | How verified |
|---|---|---|---|
| StatefulSet | `iot/emqx`, 1 replica | same | `kubectl -n iot get sts emqx` |
| volumeClaimTemplate | `emqx-data`, **20Mi**, `storageClassName: ""` | same | `-o jsonpath='{.spec.volumeClaimTemplates[*]}'` |
| PVC | `emqx-data-emqx-0`, 20Mi, `longhorn`, Bound | same | `kubectl -n iot get pvc` |
| Filesystem used | 1.20 MB (7.7%) | 1.26 MB (8.0%) | `kubelet_volume_stats_used_bytes` |
| Growth over 7 days | **−20 KiB** | **+384 KiB** | same metric with `offset 7d` |
| Chart | `emqx` 5.8.9 from `https://repos.emqx.io/charts` | same | [EMQX.yaml](../gitops/argocd-manifests/apps/iot/EMQX.yaml) |
| ArgoCD app | `emqx-server1`, automated + selfHeal + prune | `emqx-server2` | same |

`20Mi` is the **chart default** — `helm show values emqx/emqx --version 5.8.9` lists `persistence.size: 20Mi`. [gitops/helm-values/emqx.yaml](../gitops/helm-values/emqx.yaml) never sets it.

The volume holds EMQX's mnesia state: retained messages, persistent sessions, ACL and auth data, rule-engine state. Not the message queue in flight.

## Two defects in the values file, independent of sizing

1. **`persistence.storageClass` is not a key this chart has.** The chart reads `persistence.storageClassName`. The current value is silently ignored, which is why the live volumeClaimTemplate has `storageClassName: ""`. It works only because `longhorn` is the cluster-default StorageClass — the intent is expressed nowhere the chart can see it, and it breaks silently the day the default class changes.
2. **`persistence.size` is unset**, so the volume is whatever the chart happens to default to. That default changing on a chart bump would be invisible.

Both are one-line fixes and should land in the same change as any resize:

```yaml
# gitops/helm-values/emqx.yaml
persistence:
  enabled: true
  storageClassName: "longhorn"   # was storageClass — wrong key, silently ignored
  size: 1Gi                      # was unset — chart default is 20Mi
```

## Is expansion actually needed?

Honestly: **not urgently, and the case is weak on today's data.** Both volumes sit near 1.2 MB of 20 MiB. Over the 7 days of history available, server1 *shrank* by 20 KiB and server2 grew by 384 KiB. Extrapolating server2's number linearly gives roughly a year to fill, and mnesia growth is not linear — it churns.

The argument for doing it anyway is that the cost is a maintenance window now versus an outage later: EMQX is the MQTT broker for Loxone and the MiOT bridge, and a broker that cannot write its mnesia store fails in ways that are not obvious from the outside. 20 MiB is small enough that a single retained-message experiment could consume it.

The argument against is that it is not free — see the procedure. Reasonable to defer, provided the `Filesystem used` panel is actually watched.

**Recommendation:** fix the two values defects now, since they cost nothing and are strictly correctness. Do the resize opportunistically, next time EMQX is being touched for another reason.

## Why this is not a one-line values change

`StatefulSet.spec.volumeClaimTemplates` is **immutable**. Changing `persistence.size` and letting ArgoCD sync produces:

```
StatefulSet.apps "emqx" is invalid: spec: Forbidden: updates to statefulset spec
for fields other than 'replicas', 'ordinals', 'template',
'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden
```

The sync fails, EMQX keeps running on the old spec, and the app sits Degraded. The StatefulSet object has to be replaced. Separately, the existing PVC is **not** resized by changing the template — `volumeClaimTemplates` only governs PVCs the controller creates, so an existing claim has to be expanded on its own.

Good news: the `longhorn` StorageClass has `allowVolumeExpansion: true` (verified on all three clusters), and per the Longhorn 1.11 docs, **online expansion is supported since 1.4.0** — the volume can be resized while attached and in use. Expansion runs in two stages, block device then filesystem.

## Options

| Option | What it does | Cost | Risk |
|---|---|---|---|
| **A. Expand PVC, then replace the StatefulSet** (recommended) | patch the live PVC to the new size, then `kubectl delete sts --cascade=orphan` and let ArgoCD recreate it with the matching template | one sync per cluster, possible single pod restart | low — the pod keeps running through the orphan delete; data is never unbound |
| **B. ArgoCD `Replace=true`** | add the sync option so ArgoCD deletes and recreates the StatefulSet itself | one values change | higher — `Replace=true` applies to the whole app, not just this resource, and is easy to leave switched on by accident |
| **C. New PVC + migrate** | provision a second volume, copy mnesia across, repoint | hours | unnecessary here; only needed if shrinking or changing StorageClass |
| **D. Do nothing, keep watching** | rely on the `Filesystem used` panel | zero | acceptable today; revisit if growth turns non-flat |

## Procedure for option A

Per cluster, one at a time, server2 first (server1 carries the Loxone integration). Substitute `<ctx>` with `admin@server1` / `admin@server2`.

**1. Land the values change** — the two defect fixes plus the new size — and commit.

**2. Hard-refresh the app.** `emqx.yaml` is a `$values` ref source against a chart pinned at `5.8.9`, so repo-server can serve a cached manifest against the new sha. This is the failure mode documented in the dashboard plan; skipping it produces a "Synced" app running the old spec.

```bash
kubectl -n argocd annotate app emqx-<cluster> argocd.argoproj.io/refresh=hard --overwrite
```

**3. Expand the live PVC.** Do this *before* replacing the StatefulSet, so the two never disagree:

```bash
kubectl --context <ctx> -n iot patch pvc emqx-data-emqx-0 \
  --type merge -p '{"spec":{"resources":{"requests":{"storage":"1Gi"}}}}'
kubectl --context <ctx> -n iot get pvc emqx-data-emqx-0 -w   # wait for .status.capacity to reach 1Gi
```

Longhorn resizes the block device and then the filesystem. Watch the volume in the Longhorn UI if it stalls.

**4. Replace the StatefulSet, keeping the pod alive:**

```bash
kubectl --context <ctx> -n iot delete sts emqx --cascade=orphan
```

The pod and the PVC survive. ArgoCD's automated sync recreates the StatefulSet from the new template within a couple of minutes and adopts the running pod. `selfHeal: true` and `prune: true` are already set, so no manual sync is needed.

**5. Confirm whether the pod restarted.** The pod template does not change — only `volumeClaimTemplates` — so adoption *may* happen without a restart. This has not been tested here. Assume a restart and a brief MQTT disconnect for Loxone and the MiOT bridge; both reconnect on their own, but do not run this during anything that matters.

## Verification

```bash
kubectl --context <ctx> -n iot get sts emqx \
  -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}{"\n"}'   # 1Gi
kubectl --context <ctx> -n iot get pvc emqx-data-emqx-0 \
  -o jsonpath='{.status.capacity.storage}{"\n"}'                                        # 1Gi
kubectl --context <ctx> -n iot exec emqx-0 -- df -h /opt/emqx/data                      # ~1G
```

Then, in Prometheus — the number that proves the filesystem actually grew, not just the claim:

```promql
kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="emqx-data-emqx-0"}
```

Both clusters should report ~1 GiB. The `Filesystem used` bargauge on the `Platform` dashboard should drop to well under 1%.

Finally, confirm EMQX itself is healthy — retained messages and rules survive the restart:

```bash
kubectl --context <ctx> -n iot exec emqx-0 -- emqx ctl broker
kubectl --context <ctx> -n iot exec emqx-0 -- emqx ctl rules list
```

## Rollback

The PVC expansion is **not reversible** — Kubernetes and Longhorn both refuse to shrink a volume. That is acceptable because a larger volume is never the problem, but it means step 3 is the point of no return. Everything before it is a values revert.

If the StatefulSet recreation goes wrong, the data is safe: it lives in the PVC, which is never deleted in this procedure. Recreate the StatefulSet by syncing the app; worst case, `kubectl -n argocd app sync emqx-<cluster>` or a hard refresh.

## Open questions for whoever picks this up

1. **Is 1Gi the right target?** It is a guess — 50× headroom on a workload using 1.2 MB. 256Mi would also be defensible and wastes less of a thin-provisioned pool. Longhorn allocates lazily, so the larger claim costs nothing until written.
2. **Does the orphan-delete actually avoid a pod restart?** Worth testing on server2 and recording the answer here.
3. **Should `persistence.size` be per-cluster?** Both clusters run identical EMQX workloads today, so shared base values are right; the per-cluster override file exists and is currently empty of Helm values.
4. **Is there a retention setting that bounds mnesia growth instead?** Retained-message expiry and session expiry are EMQX config, not storage. Bounding growth may be a better answer than a bigger volume, and it is not investigated here.
5. **Do the same defects exist for the other charts?** `persistence.storageClass` vs `storageClassName` is a per-chart spelling. InfluxDB2 and MongoDB values are worth the same 30-second check.

## Do not

- **Do not** change `persistence.size` and sync without replacing the StatefulSet. The sync fails and the app goes Degraded with no explanation at the values layer.
- **Do not** delete the StatefulSet without `--cascade=orphan`. That takes down the pod, and with `prune: true` on the app it is an unnecessarily exciting few minutes.
- **Do not** delete the PVC. It is the mnesia store — retained messages, sessions and ACLs — and there is no backup target configured on Longhorn (see the dashboard plan's open problems).
- **Do not** try to shrink later. Pick the size once.
