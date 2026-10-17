---
name: probe-traffic
description: "Generate real traffic against the homelab clusters and observe what it produced. Use when: verifying telemetry actually flows (logs/traces/metrics), testing network reachability or egress, validating NetworkPolicy before or after a change, proving an app path works end-to-end, or investigating 'ArgoCD says Healthy but is anything happening?'. Sends correlated requests from a chosen vantage point, then verifies through a chosen lens."
argument-hint: "What to test, e.g. 'do sandbox app logs reach Loki' or 'can miot-bridge still reach EMQX after the policy change'"
---

# probe-traffic

Two decoupled halves: **send traffic** (vantage) and **look at what it produced** (lens). Pick one of each — they are independent. The pairing depends on what is being investigated, not on a fixed script.

The skill exists because *green does not mean working*. ArgoCD `Synced`/`Healthy` with Running pods proves manifests applied. It does not prove a single byte moved. This skill moves bytes and then goes looking for them.

All custom apps run on **server1**, in `production` and `sandbox`. Telemetry from every cluster lands on server3 and is read through the Grafana MCP.

## Prerequisites

- Laptop CLIs: `curl`, `xxd`, `kubectl`. Not needed locally: `hubble` and `cilium-dbg` run inside the Cilium agent pod; `mongosh`, `influx`, `bao` and GNU `timeout` run inside the probe image (V3/V4). macOS has no `timeout` — use `curl -m`.
- Cluster access for V2–V4 and the flows/drops lenses: `export KUBECONFIG=iac/clusters/server1/credentials/kubeconfig`.
- Telemetry lens: Grafana MCP tools `mcp__grafana__query_loki_logs`, `mcp__grafana__query_prometheus`, `mcp__grafana__grafana_api_request` (Tempo). Datasource UIDs: `loki`, `prometheus`, `tempo`.
- V1 needs the laptop on the LAN.

## The one thing that makes this work: correlation

Every run mints two ids **before** sending anything:

- `RUN_ID` — an opaque string, carried as `X-Probe-Run` header, `?probe=` query param, and User-Agent.
- `TRACE_ID` — a 32-hex W3C trace id, sent as a `traceparent` header.

**Traefik honours the injected `traceparent` and propagates it to the app** (re-verified on server1 2026-10-06: Traefik access log `TraceId`, the app log's `trace_id` and the Tempo trace all equal the minted id). So the probe *chooses* its own trace id in advance, and every lens becomes an exact lookup instead of a search:

| Lens | Lookup |
|---|---|
| Loki | `\| trace_id="<TRACE_ID>"` (structured metadata) or `\|= "<RUN_ID>"` |
| Tempo | fetch that exact trace by id — no TraceQL search needed |
| Hubble | filter by pod/port, correlate on wall-clock |

Mint them once per run:

```bash
RUN_ID="probe-$(date +%s)-$(head -c4 /dev/urandom | xxd -p)"
TRACE_ID=$(head -c16 /dev/urandom | xxd -p)
SPAN_ID=$(head -c8 /dev/urandom | xxd -p)
```

## Procedure

Copy this checklist into your response and tick it off:

```
Probe run:
- [ ] 1. Question stated in one sentence
- [ ] 2. Vantage picked (V1–V4)
- [ ] 3. Target picked from references/targets.md; expected status known (401 is normal for anonymous API calls)
- [ ] 4. Shape picked (single / burst / sustained)
- [ ] 5. V4 only: orphan probe-* pods swept
- [ ] 6. Live-capture lens (Hubble, cilium monitor) started BEFORE sending
- [ ] 7. Sent; RUN_ID and TRACE_ID recorded
- [ ] 8. Each lens checked, retried to its deadline before calling MISS
- [ ] 9. Report written, one line per signal, misses included
```

### 1. State what is being investigated

One sentence, before touching anything. It selects the vantage and the lens. "Do sandbox logs reach Loki" and "can the app still resolve DNS under the new policy" need completely different setups.

### 2. Pick a vantage — how traffic gets sent

| | Mechanism | Use when isolating |
|---|---|---|
| **V1 laptop** | `curl` to `https://<component>.[sandbox.]server1.homelab.irha.cz/...` | the full path: DNS → Traefik → HTTPRoute → Service → pod |
| **V2 port-forward** | `kubectl port-forward` to Service or pod | the app alone, with Traefik removed from the picture |
| **V3 in-pod** | `kubectl debug --target` into the app pod | **egress as the app** — DNS, Mongo, EMQX, LAN UDP, internet. The only correct vantage for NetworkPolicy work |
| **V4 standalone pod** | `kubectl run --rm` with chosen labels | negative tests — what a pod that *should not* reach X can actually reach |

Prefer V3 over V4 when the question is "can this app reach X", because V3 inherits the app pod's network namespace and therefore its exact Cilium identity — a policy verdict from V4 is a verdict about a different pod.

Exact commands, caveats, and the ephemeral-container residue rule: [references/vantages.md](references/vantages.md).

### 3. Pick a target — and check what it actually emits

`/health/live` and `/health/ready` are **useless as probes**: they are excluded from access logging and emit no telemetry. Probing them proves nothing about the observability pipeline.

The endpoint inventory — which paths are safe to call repeatedly, which need a token, and which signals each one produces — is [references/targets.md](references/targets.md). Read it before choosing. It also carries the URL construction rules and every in-cluster service address.

### 4. Choose a shape

- **single** — one request. Enough for logs/traces.
- **burst** — N requests. Needed before metrics move visibly.
- **sustained** — loop at an interval. Required for Hubble (its ring buffer holds ~60s) and for rate-based PromQL.

### 5. Start the lens BEFORE sending, when the lens is live-capture

Hubble and `cilium monitor` are live streams over a ring buffer that turns over in about a minute. Start the follow, *then* send. If the follow started late, the run is void — send again. Loki/Tempo/Prometheus are stores and can be queried afterwards.

### 6. Send

### 7. Verify through the lens — retry before calling MISS

Lenses and their exact, verified queries: [references/lenses.md](references/lenses.md).

- **response** — status, latency, headers. No cluster access needed.
- **telemetry** — Loki, Tempo, Prometheus. Per-signal PASS/MISS **and time-to-appear**.
- **flows** — Hubble verdicts: FORWARDED / DROPPED.
- **drops** — `cilium-dbg monitor --type drop`, policy denials.
- **delivery** — did the side effect land: MQTT message, Mongo document, Influx point.

Loki needs ~7 s and Tempo answers `404` for a few seconds after the request. Re-query until the signal appears or ~90 s pass; only then is it a MISS.

### 8. Report

Report what was observed, per signal, including misses. A miss is a finding, not a failure of the run.

```
Run:     <RUN_ID>   trace <TRACE_ID>
Vantage: V1 laptop → api.sandbox.server1.homelab.irha.cz
Target:  GET /iot/interactive-map-feeder/data-sources/list  (sandbox, anonymous)
Shape:   single

response     PASS  401 in 18ms (expected: anonymous)
loki:traefik PASS  +5s
loki:app     PASS  +5s
tempo        PASS  +9s  traefik → interactive-map-feeder-api
prometheus   not checked
```

Never report a signal as PASS without having seen the data. If a lens was not run, say "not checked" — not "OK".

## Safety

- **Read-only endpoints by default.** GET only. Anything that writes needs the operator to say so explicitly, per run.
- **Never follow redirects on `qr-manager-api /:slug`** — the redirect target is user-supplied data pointing anywhere. Record `%{redirect_url}`, do not fetch it.
- **Prefer sandbox over production** whenever the question can be answered in either.
- **This skill never applies policy**, never edits manifests, never syncs ArgoCD. It observes. Policy changes go through the `network-egress` skill.
- **Clean up.** `kubectl run` always with `--rm`. Sweep for orphaned `probe-*` pods on entry. Ephemeral containers cannot be removed without restarting the pod — see [references/vantages.md](references/vantages.md).
- **Never touch anything holding data** — PVCs, PVs, Longhorn volumes, StatefulSets.
- **Never echo a token** into commands you show, logs or the report.
- Traffic is real traffic. It appears in dashboards, counts toward metrics, and is visible to anyone else looking at the cluster.

## Auth

The APIs require a bearer token (the IoT ones since 2026-09-09); anonymous calls get `401`. **A `401` is still a complete telemetry probe** — Traefik logs it, the app logs it with `trace_id`, and Tempo holds the trace. Authenticate only when the question needs the handler to run (internet egress, a real Mongo read): ask the operator for a token in `PROBE_TOKEN` and send `-H "Authorization: Bearer $PROBE_TOKEN"`. Details: [references/targets.md](references/targets.md).

## Before believing a negative result

A MISS has three common innocent explanations before it is a real defect: the lens was started too late, the signal needs more volume than one request, or not enough time has passed. [references/gotchas.md](references/gotchas.md) lists the traps that have actually bitten in this homelab. Read it before declaring something broken.
