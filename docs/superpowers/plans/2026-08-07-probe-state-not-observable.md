# Probe State Is Not Observable — `kube_pod_status_ready` Is Not Collected

> **Status:** Metric collection **implemented and verified** on 2026-08-11 (commit `92efe99`).
> Alerting is still open — see "Alerting spec" below, which supersedes the naive query in
> the original Verification section.
> **Related:** `docs/superpowers/plans/2026-08-06-iot-app-health-checks.md` (Rule 5 and
> the "Alerting on probe state" follow-up both assume the metric described here already
> exists). Also `docs/superpowers/plans/2026-05-18-service-instrumentation.md`.

## Problem

The health-checks plan adds readiness probes to the five custom apps so a dependency
outage takes a pod out of the Service's Endpoints instead of silently serving errors.
It then defers alerting to a follow-up, on the stated basis that:

> `kube_pod_status_ready` and `kube_pod_container_status_restarts_total` already land in
> server3's Prometheus via k8s-monitoring.

**Only the second of those is true.** Queried against the `Prometheus` datasource on
server3 on 2026-08-07:

| Metric | Present | What it would tell us |
| --- | --- | --- |
| `kube_pod_container_status_restarts_total` | yes | a liveness kill loop |
| `kube_pod_status_phase` | yes | Running / Pending / Failed |
| `kube_pod_status_reason` | yes | eviction, node lost |
| `kube_pod_container_status_waiting_reason` | yes | `CrashLoopBackOff`, `ImagePullBackOff` |
| `kube_pod_container_status_last_terminated_reason` | yes | OOMKilled |
| **`kube_pod_status_ready`** | **no** | **readiness is failing right now** |
| `prober_probe_total` | no | probe successes/failures, by probe type |
| `prober_probe_duration_seconds` | no | probe latency |

So once the health-checks plan lands, this happens:

1. MongoDB blips. Every replica of `qr-manager-api` and `miot-bridge-api` fails readiness.
2. Endpoints empties. Traefik stops routing. The apps are down.
3. Liveness is shallow by design, so **nothing restarts** — `restarts_total` stays flat.
4. `kube_pod_status_phase` still reports `Running`, because the pods are running.
5. **No metric in Prometheus changes.** No alert can fire.

The outage is invisible to monitoring precisely because the probes did their job. That is
a worse failure mode than today, where at least the errors reach the request logs. It is
the same class as the "green does not mean working" warning in `AGENTS.md`, one layer up.

## Why the metric is missing

`gitops/helm-values/k8s-monitoring.yaml` enables `clusterMetrics` and deploys
kube-state-metrics, but sets no `metricsTuning` anywhere. So the k8s-monitoring chart's
**default allow-list** applies, and it does not include `kube_pod_status_ready`. Nothing
is misconfigured — this is the chart's out-of-the-box behaviour, and it went unnoticed
because nothing depended on the metric until now.

Kubelet's own `prober_*` series are a separate question: they are not part of
kube-state-metrics at all, and would need the kubelet scrape target plus its own
allow-list entry.

## What needs deciding

For whoever picks this up — these are open, not decided:

1. **Which metrics to add.** `kube_pod_status_ready` is the minimum and is sufficient for
   a "NotReady > 5m" alert. `prober_probe_total` additionally distinguishes *which* probe
   is failing and how often, which matters when tuning `failureThreshold`. Worth the extra
   scrape target, or not?
2. **How to add them.** k8s-monitoring **v4.3.2**, pinned in
   `gitops/argocd-manifests/apps/observability/K8sMonitoring.yaml`. v4 moved these under
   the `telemetryServices` subchart, so the key path is not the same as in v3 docs —
   verify against the pinned chart rather than a blog post. Check whether the right shape
   is `metricsTuning.includeMetrics` (additive to the default allow-list) or replacing
   `useDefaultAllowList`; the former is much less likely to drop something else by accident.
3. **Cost.** `kube_pod_status_ready` is one series per pod per condition. Small, but this
   is a homelab and the same reasoning that produced a default allow-list applies — worth
   a sentence, not a study.
4. **Whether the alert belongs in this change or stays a follow-up.** The metric is
   useless without something reading it, and a metric added "for later" tends to stay
   that way. Suggest landing at least one alert alongside it.

## Verification

The whole point is that this is checkable, so check it rather than trusting a sync status:

```promql
# Must return series after the change. Returns nothing today.
kube_pod_status_ready{namespace="sandbox"}

# The alert this is for: a custom app NotReady for more than 5 minutes.
min_over_time(kube_pod_status_ready{condition="true", namespace=~"sandbox|production"}[5m]) == 0
```

End-to-end, once the health-check probes exist: scale MongoDB to 0 in `sandbox`, confirm
`kube_pod_status_ready` goes to 0 for the affected pods while
`kube_pod_container_status_restarts_total` stays flat, then scale it back and confirm
recovery without intervention. That single test exercises the metric, the probe, and the
"liveness must be shallow" rule at once.

## Notes for the implementer

- **Ordering.** This is only *useful* after the health-checks plan lands, but it is not
  *blocked* by it and is much smaller. Landing it first means the probe rollout can be
  watched on a dashboard as it happens, rather than retro-fitting observability onto a
  change whose entire purpose is to make failure visible.
- **Do not solve this in the applications.** An earlier draft of the `iot-miniservers`
  backend spec proposed a custom `health.check.duration` metric emitted by the apps. It
  was dropped: there is no OpenTelemetry semantic convention for health checks, so the
  name would mean nothing to any dashboard or mixin, and it would measure the app's own
  check rather than the dependency or the probe outcome. Probe state is a Kubernetes-layer
  fact and belongs to kubelet and kube-state-metrics. This document is the correct place
  to fix it.
- The apps' `http_server_request_duration_seconds` **is** already flowing and is unaffected.
  The `iot-miniservers` change deliberately excludes `/health*` from it, so it will not
  serve as a probe-state substitute — another reason this gap has to be closed here.

## What was implemented (2026-08-11, commit `92efe99`)

Both open metric questions were resolved in favour of collecting more, in
`gitops/helm-values/k8s-monitoring.yaml`:

1. **`kube_pod_status_ready`** added via
   `clusterMetrics.kube-state-metrics.metricsTuning.includeMetrics`. Confirmed against the
   pinned chart that `includeMetrics` is **additive** — `_kube_state_metrics.alloy.tpl`
   concatenates the default allow-list with the additions, so `useDefaultAllowList` stays
   `true` and nothing is dropped. 576 series (~3 per pod, one per condition value).
2. **`clusterMetrics.kubeletProbes.enabled: true`** for kubelet's `prober_*` counters,
   with `prober_probe_duration_seconds` excluded. It reuses the node discovery,
   serviceaccount token and TLS config of the already-enabled `kubelet` scrape, so it
   needed **no extra RBAC** — the only cost is the extra scrape of `/metrics/probes`.
   294 series. The histogram was dropped as ~7x the cost of the rest of `prober_*` for a
   probe-latency question nothing currently asks; timeouts still surface in
   `prober_probe_total` as `result="failed"`.

Decision 4 (whether alerting lands together) went the other way: alerting is deferred
because there is no notification channel yet. Alertmanager is disabled and no Grafana
contact point exists, so an alert would have had nothing to fire into.

### Verified results — the MongoDB test

The end-to-end test this document asks for was run on server2 on 2026-08-11: `mongodb`
StatefulSet scaled to 0, apps observed, then recovery confirmed.

**Note for whoever repeats it: MongoDB is not per-environment.** There is one release per
cluster in the `mongodb` namespace and `gitops/helm-values/apps/common/values.yaml` points
*both* `sandbox` and `production` at it, so this test is not sandbox-scoped — it takes
production apps down on the chosen cluster too. Scaling the StatefulSet does not touch
`datadir-mongodb-0`; the PVC stayed `Bound` on the same volume throughout.

Result, exactly as predicted:

| Pod | Depends on MongoDB | `kube_pod_status_ready` | restarts |
| --- | --- | --- | --- |
| `qr-manager-api` (sandbox + production) | yes | 1 → **0** | 0 |
| `miot-bridge-api` (sandbox + production) | yes | 1 → **0** | 0 |
| `interactive-map-feeder-api` (×4) | no | 1 throughout | 0 |
| `qr-manager-ui` (×2) | no | 1 throughout | 0 |

`kube_pod_container_status_restarts_total` recorded **zero** increase across every
namespace. That is the whole point of the document: a total dependency outage, four pods
pulled from their Service Endpoints, and the pre-existing metrics would have shown nothing.

`prober_*` resolved it to the individual probe. For `qr-manager-api` in sandbox:

```text
Readiness successful   828 → 832   (+4, normally +12 per minute)
Readiness failed       series did not exist → 9
Liveness  successful   413 → 419   (+6, unbroken, never failed)
Startup                unchanged
```

Liveness passing while readiness fails is the shallow-liveness rule working, now visible
as data rather than asserted in a plan. Note the `Readiness failed` series is *born* at
first failure — `increase()` and `rate()` return nothing for it until a second sample
exists, so an alert must not depend on a rate over a series that may not exist yet.

Recovery needed no intervention: ArgoCD `selfHeal` restored the StatefulSet and all ten
pods returned to Ready with restart counts still at 0.

### Verified results — pod roll

A rolled sandbox pod produced the complete picture the plan was written to get:

```text
Startup   failed=4  successful=1     app booting
Readiness successful=7
Liveness  successful=3
kube_pod_container_status_restarts_total = 0
kube_pod_status_ready:  0 → 0 → 1
```

Untouched replicas stayed at `1` throughout. The shallow-liveness / deep-readiness split
is now directly observable rather than inferred.

`prober_*` also immediately surfaced an unrelated three-month-old crash-loop
(`loki-canary`, 30k restarts from a values key that silently never applied), which is a
fair demonstration that the signal is worth its cost.

## Alerting spec — supersedes the query in "Verification"

**Do not use bare `kube_pod_status_ready == 0`.** kube-state-metrics reports
`ready=0` for *terminated* pods too, and server1 currently carries 28 orphaned
`Completed`/`Error` pods aged 50–99 days. The original query returns 6 of them and would
fire permanently on pods that no longer exist in any meaningful sense.

Gate on the pod actually running:

```promql
kube_pod_status_ready{condition="true"} == 0
  and on (cluster, namespace, pod) kube_pod_status_phase{phase="Running"} == 1
```

Returns 0 against a healthy cluster, versus 6 false positives for the naive form. Wrap in
`min_over_time(...[5m])` — or an alert `for: 5m` — to require the condition to persist.

`prober_probe_total` supplies the annotation that makes such an alert actionable:
`probe_type` distinguishes a dependency-gated readiness failure from a liveness kill loop,
which is exactly the discrimination `kube_pod_status_ready` alone cannot make. Use it for
enrichment, not as the alert condition — the `result="failed"` series does not exist until
the first failure, so any `rate()` over it is empty precisely when it matters most.

Remaining work: a notification channel, a contact point, and the rule itself. Note also
that `prober_probe_total` carries a `pod_uid` label, so its series count grows with pod
churn; drop it with a `labeldrop` rule under `kubeletProbes.extraMetricProcessingRules`
if that becomes a problem.
