# Gotchas — traps that have actually bitten here

## Contents

- Green does not mean working
- `/health` endpoints emit nothing
- `401` from an API is a successful probe
- The Hubble ring buffer turns over in ~60 seconds
- Idle flows are invisible, and that is not a policy question
- Loki index labels are OTel names, not Loki names
- Telemetry lag is real — Loki ~7 s, Tempo 404s at first
- One request does not move a rate
- Ephemeral containers are permanent for the pod's life
- The `kubectl debug` PodSecurity warning is not an error
- `stripPrefix` changes the path between V1 and V2
- `pathName` already contains `iot/`
- A Swagger path without its trailing slash loses the prefix
- `ds/cilium` is only unambiguous on a single-node cluster
- macOS host lacks `timeout`
- Applying part of the policy set causes an outage
- A green Synced badge can hide an undeployed change
- The redirect from `qr-manager-api /<slug>` points at user data

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

## `401` from an API is a successful probe

The APIs require a bearer token. An anonymous request gets `401` from the app's auth guard — after
Traefik logged it, the app logged it with `trace_id`, and the trace was exported. Report it as
`response PASS 401 (expected: anonymous)`. Only a `401` where you sent a token is a finding.

## The Hubble ring buffer turns over in ~60 seconds

~4095 events per node, ~4000 flows/minute. `hubble observe --last N` is not a retrospective
tool here. Start `--follow` **before** generating traffic. If the follow was started after,
the run is void — send again rather than reasoning about a gap.

## Idle flows are invisible, and that is not a policy question

Three flows produce zero traffic under normal idle conditions:

- **DNS** — app pods hold long-lived connections and resolved names at startup. In the
  2026-08 flow inventory the app workloads emitted zero DNS queries over 18 minutes.
- **CHMI internet egress** — only during a user request; the upstream health check is
  deliberately passive and issues no synthetic request.
- **miIO LAN egress** — only while a registered device is being polled; a miot-bridge pod with
  no devices polls an empty list.

An empty Hubble window for these means nothing was asked of them. Generate the traffic, or use
`http_client_request_duration_seconds{server_address=...}` in Prometheus, which retains ~30 days
of per-destination evidence.

## Loki index labels are OTel names, not Loki names

Logs arrive over Loki's native OTLP endpoint, so the index labels are `k8s_cluster_name`,
`k8s_namespace_name`, `k8s_pod_name`. Plain `cluster`, `namespace` and `pod` exist only as
**structured metadata** — a stream selector on `{cluster="server1"}` matches nothing and looks
exactly like "the logs are missing".

## Telemetry lag is real — Loki ~7 s, Tempo 404s at first

Measured request-to-queryable in Loki: ~7 s. Tempo answers `404` for a trace id queried in the
first seconds (seen 2026-10-06; the same id returned the full trace moments later). Querying
immediately produces a false MISS. Retry to a ~90 s deadline, and report the time-to-appear
alongside the verdict.

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

The APIs have `stripPrefix: true`: Traefik removes `/<pathName>` before the app sees the
request. So the laptop URL carries the prefix and the port-forward URL must not. qr-manager-ui
is the exception (`stripPrefix: false`). A 404 from the wrong form proves nothing.

## `pathName` already contains `iot/`

`ingress.pathName` for the APIs is `iot/miot-bridge`, not `miot-bridge`. Building a URL from
`partOf` **and** `pathName` doubles the segment. Read the values file.

## A Swagger path without its trailing slash loses the prefix

`/iot/qr-manager/api/docs` answers `302` to `/api/docs/` — without the `/iot/qr-manager` prefix,
which then 404s. Always request the Swagger paths with the trailing slash.

## `ds/cilium` is only unambiguous on a single-node cluster

server1 has one node today. Every `exec ds/cilium` in this skill assumes that. Adding a node
silently makes those commands address an arbitrary agent.

## macOS host lacks `timeout`

`timeout` is a GNU coreutils binary; it is not on the macOS host by default. Inside the probe
container (debian) it is available. Put timeouts inside the container command, or use `curl -m`.

## Applying part of the policy set causes an outage

In Cilium's `default` enforcement mode, a policy that *selects* a pod flips that pod's direction
to deny-by-default. An egress rule applied without the DNS rule denies DNS immediately. The
policy set under `gitops/k8s-manifests/server1/network-policies/<environment>/` is one unit. This
skill never applies policy — it observes; changes go through the `network-egress` skill.

## A green Synced badge can hide an undeployed change

Irrelevant to probing, relevant the moment a probe result leads to a manifest change. Most apps
deploy a push within ~3 min, but values-only commits hit a stale multi-source cache and read
`Synced` while serving the old values — compare `status.sync.revision(s)` with
`git rev-parse origin/main`. The network-policies Applications are manual-sync and deploy nothing
until synced.

## The redirect from `qr-manager-api /<slug>` points at user data

It is a URL someone stored. Record `%{redirect_url}`; never pass `-L`.
