# Probe State Is Not Observable — `kube_pod_status_ready` Is Not Collected

> **Status:** Problem statement. Needs analysis, refinement and implementation.
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
