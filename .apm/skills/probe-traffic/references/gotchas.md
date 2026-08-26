# Gotchas — traps that have actually bitten here

Read this before declaring a signal missing or a component broken.

## Green does not mean working

ArgoCD `Synced`/`Healthy` with Running pods proves the manifests applied. During the
k8s-monitoring migration two separate bugs — a scrape gated behind
`hostMetrics.linuxHosts.enabled`, and an OTLP exporter that could not start — sat green for
hours while collecting nothing. Verify by querying data. This entire skill exists because of
that class of failure.

## `/health` endpoints emit nothing

`/health/live`, `/health/ready` and the nginx `/healthz` are excluded from access logs and
produce no telemetry. A probe against them proves the process answers TCP, and nothing else.
Never use them to test the observability pipeline.

## The Hubble ring buffer turns over in ~60 seconds

~4095 events per node, ~4000 flows/minute. `hubble observe --last N` is not a retrospective
tool here. Start `--follow` **before** generating traffic. If the follow was started after,
the run is void — send again rather than reasoning about a gap.

## Idle flows are invisible, and that is not a policy question

Three flows produce zero traffic under normal idle conditions:

- **DNS** — app pods hold long-lived connections and resolved names at startup. Over 18 minutes
  the four server2 app workloads emitted zero DNS queries.
- **CHMI internet egress** — only during a user request; the upstream health check is
  deliberately passive and issues no synthetic request.
- **miIO LAN egress on server2** — both server2 miot-bridge pods have zero registered devices,
  so the 5 s poller runs against an empty list.

An empty Hubble window for these means nothing was asked of them. Generate the traffic, or use
`http_client_request_duration_seconds{server_address=...}` in Prometheus, which retains ~30 days
of per-destination evidence.

## Loki index labels are OTel names, not Loki names

Logs arrive over Loki's native OTLP endpoint, so the index labels are `k8s_cluster_name`,
`k8s_namespace_name`, `k8s_pod_name`. Plain `cluster`, `namespace` and `pod` exist only as
**structured metadata** — a stream selector on `{cluster="server2"}` matches nothing and looks
exactly like "the logs are missing".

## Telemetry lag is real — about 7 seconds, sometimes more

Measured request-to-queryable in Loki: ~7 s. Querying immediately after sending produces a false
MISS. Retry to a ~90 s deadline, and report the time-to-appear alongside the verdict.

## One request does not move a rate

`increase(...[5m])` over a single request rounds to invisible. Metric lenses need a burst, or a
before/after read of the raw counter.

## Ephemeral containers are permanent for the pod's life

`kubectl debug --target` cannot be undone. The container stays in the pod's status until the pod
is deleted or restarted, and its name must be unique per pod. Prefer sandbox targets; use
`--container=probe-$(date +%s)` when repeating against one pod.

## The `kubectl debug` PodSecurity warning is not an error

`Warning: would violate PodSecurity "restricted:latest"` is a warning; the container starts.
Do not "fix" it with `--profile=restricted` — that sets `runAsNonRoot=true` and the provisioner
image runs as root, so the probe would not start at all.

## `stripPrefix` changes the path between V1 and V2

The three APIs have `stripPrefix: true`: Traefik removes `/iot/<app>` before the app sees the
request. So the laptop URL carries the prefix and the port-forward URL must not. qr-manager-ui
is the exception (`stripPrefix: false`). A 404 from the wrong form proves nothing.

## `pathName` already contains `iot/`

`ingress.pathName` for the APIs is `iot/miot-bridge`, not `miot-bridge`. Building a URL from
`partOf` **and** `pathName` doubles the segment. Read the values file.

## `ds/cilium` is only unambiguous because these are single-node clusters

server1 and server2 each have one node today. Every `exec ds/cilium` in this skill assumes that.
Adding a node silently makes those commands address an arbitrary agent.

## macOS host lacks `timeout`

`timeout` is a GNU coreutils binary; it is not on the macOS host by default. Inside the probe
container (debian) it is available. Put timeouts inside the container command, or use `curl -m`.

## Applying part of the draft allowlist causes an outage

In Cilium's `default` enforcement mode, a policy that *selects* a pod flips that pod's direction
to deny-by-default. `20-allow-egress-in-cluster.yaml` applied alone denies DNS immediately. The
draft set is one atomic unit. This skill never applies policy — it observes.

## ArgoCD does not auto-deploy here

Periodic reconciliation is broken upstream in this setup; pushing a commit is not deploying it.
Irrelevant to probing, relevant the moment a probe result leads to a manifest change: the change
needs a manual Sync, and values-only commits need a hard refresh before the Synced badge means
anything.

## The redirect from `qr-manager-api /<slug>` points at user data

It is a URL someone stored. Record `%{redirect_url}`; never pass `-L`.
