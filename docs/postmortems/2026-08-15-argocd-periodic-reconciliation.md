# ArgoCD stopped reconciling on a timer

**Status:** open, unmitigated by choice. Upstream bug, no fix released.
**Found:** 2026-08-15, while wondering why a pushed commit had not deployed after ~10 hours.
**Affects:** every Application on server3's ArgoCD — 67 of them, all clusters.

## Summary

ArgoCD's periodic reconciliation does not run. Applications are refreshed only when a **watch event** fires on one of their managed resources, or when a human clicks Sync/Refresh. `timeout.reconciliation` is set to `120s` and is correctly loaded by the controller, and it makes no difference.

On a homelab this is worse than on a busy cluster: at night nothing changes, so there are no watch events at all, and reconciliation stops completely for hours. A commit pushed at 20:20 was still not deployed at 05:34 the next morning, and only deployed then because someone pressed Sync.

**`Synced` and `Healthy` remain green throughout.** Nothing alerts. The only symptom is the age of `status.reconciledAt`, which nothing scrapes.

## Timeline

| Time (UTC) | Event |
|---|---|
| 2026-08-12 19:35 | application-controller pod starts; every app reconciles once |
| 2026-08-14 20:20 | `dfc86cd` pushed |
| 2026-08-14 20:01 → 2026-08-15 05:34 | **no reconciliation of any kind, 9h27m** |
| 2026-08-15 05:34 | human clicks Sync; `grafana-server3` deploys `dfc86cd` |

## Evidence

Gathered before forming a conclusion, and each item rules something out:

| Measurement | Value | Rules out |
|---|---|---|
| `workqueue_depth` — all 5 controller queues | **0** | stuck workers, throughput limits, capacity |
| `sum(increase(argocd_app_reconcile_count[30m]))` | **0** for every 30m bucket from 20:30 to 05:00 | a purely cosmetic `reconciledAt` staleness — nothing actually ran |
| Controller pod | Running 2d9h, **0 restarts**, goroutines flat at 1834 | crashes, leaks, OOM |
| Controller log volume when idle | exactly **6 lines/hour**, all `Alloc=… Goroutines=…` memory stats | the process being wedged — it is alive and healthy |
| `ARGOCD_RECONCILIATION_TIMEOUT` in the running process | `120s` (jitter `60s`) | misconfiguration; the value is correct and correctly wired from `argocd-cm` |
| `controller.status.processors` / `operation.processors` | unset → defaults | processor starvation |
| `sum by (cluster) (up)` across 19:00–06:30 | flat, no gaps on any cluster | the node sleeping or a network outage |
| Redis mentions in 48h of controller log | **0** | cache backend problems |
| `status.reconciledAt` on most apps | `2026-08-12T19:35Z` — the controller's own start time | anything other than "the timer has never fired since startup" |

The controller does log the expiry check, and the log is where the shape becomes obvious — it notices correctly, just far too late:

```
"Refreshing app status (comparison expired, requesting refresh.
  reconciledAt: 2026-08-13 18:44:14, expiry: 2m0s)"   ← logged 2026-08-14 18:46
"Refreshing app status (comparison expired, requesting refresh.
  reconciledAt: 2026-08-14 19:32:40, expiry: 2m0s)"   ← logged 2026-08-15 05:34
```

A 2-minute expiry noticed 24 hours, then 10 hours later.

## Root cause

Upstream: **[argoproj/argo-cd#28934](https://github.com/argoproj/argo-cd/issues/28934)** — *"comparison-expiry refresh fires at ~2-3% of `timeout.reconciliation`, leaving apps with no watch events permanently unreconciled"*. Open, `bug/severity:major`, `bug/priority:high`, `component:refresh`.

The reporter measured the expiry timer firing at 1.4–3.4% of its configured rate across three shards, with reconciliation carried almost entirely by the watch-event path. Applications managing small, quiet resource sets starve — in their fleet, no starved Application managed more than 45 objects.

Our deployment is the degenerate case of the same bug: **a quiet homelab generates no watch events overnight, so both paths are silent and reconciliation reaches exactly zero.**

Related, opposite polarity: [#27192](https://github.com/argoproj/argo-cd/issues/27192) reports v3.3.5 doing 100% timer-driven refreshes and no watch-event refreshes. Same subsystem.

## Upgrading does not fix this

Running **v3.3.7** (chart `argo-cd` 9.5.2). Latest is **v3.5.1**.

The fix is [PR #28965](https://github.com/argoproj/argo-cd/pull/28965), **still open**. v3.5.1's changelog does touch this area — `treat timeout.reconciliation=0 as disabled soft expiry`, `use diff cache when timeout.reconciliation is disabled` — but not this defect. An upgrade is defensible for other reasons; it will not restore periodic reconciliation.

## Options, and what was decided

| Option | Assessment | Decision |
|---|---|---|
| CronJob sweeping `kubectl -n argocd annotate app --all argocd.argoproj.io/refresh=normal` every 5–10 min | Works, deterministic, independent of upstream. But it is a workaround pinned to a bug, and it hides the problem rather than fixing it. | **Rejected** 2026-08-15 — workaround only |
| GitHub webhook → instant refresh on push | The correct fix in general. Needs `argocd-server` reachable from github.com; everything here is `*.home` on a private network. | Not viable without a tunnel |
| Lower `timeout.reconciliation` (120s → 30s) | If the timer fires at ~2% of its rate, the effective interval scales down with it. Compensating for a bug with a magic number, and it also makes every successful refresh more frequent. | Not taken |
| Upgrade to v3.5.x | Two minor versions, own upgrade notes. Worth doing on its own merits. | Open, unrelated to this |
| Restart the controller | Reconciles everything once, then decays again. | Diagnostic only |

**Current state: unmitigated.** Deployments require a manual Sync or Refresh in the ArgoCD UI. Anyone pushing to this repo must assume nothing deploys on its own.

## How to tell it is happening

There is no built-in alert for this, because every app stays `Synced`/`Healthy`. The cheapest detector is the reconcile counter going flat:

```promql
sum(increase(argocd_app_reconcile_count[30m])) == 0
```

Zero across a 30-minute window on a cluster that is otherwise up means reconciliation has stopped. Worth a panel on the GitOps dashboard or an alert rule; neither exists yet.

Age of the last reconcile, per app, is the direct measure but is not exported as a metric:

```bash
kubectl -n argocd get app -o custom-columns=\
NAME:.metadata.name,RECONCILED:.status.reconciledAt
```

## Next steps for whoever picks this up

1. Decide whether to run with manual syncs, take the CronJob after all, or expose a webhook.
2. Track [#28965](https://github.com/argoproj/argo-cd/pull/28965); when it merges and ships, the ArgoCD bump becomes the real fix.
3. Consider the detector above regardless — this failure was invisible for at least three days before anyone noticed, and only then because a specific commit was expected to deploy.
4. Note for anyone reading the older guidance: this is **separate** from the `$values` stale-manifest-cache problem already documented in the dashboard plan. That one made `Synced` lie about *which revision* was rendered; this one means the app is never re-examined at all. Both end in "the badge is green and the cluster is old", by different mechanisms.
