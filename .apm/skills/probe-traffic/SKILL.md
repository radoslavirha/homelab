---
name: probe-traffic
description: "Generate real traffic against server1/server2/server3 and observe what it produced. Use when: verifying telemetry actually flows (logs/traces/metrics), testing network reachability or egress, validating NetworkPolicy before or after a change, proving an app path works end-to-end, or investigating 'ArgoCD says Healthy but is anything happening?'. Sends correlated requests from a chosen vantage point, then verifies through a chosen lens."
argument-hint: "What to test, e.g. 'do sandbox app logs reach Loki on server1' or 'can miot-bridge still reach EMQX under the draft netpol'"
---

# probe-traffic

Two decoupled halves: **send traffic** (vantage) and **look at what it produced** (lens). Pick one of each — they are independent. The pairing depends on what is being investigated, not on a fixed script.

The skill exists because *green does not mean working*. ArgoCD `Synced`/`Healthy` with Running pods proves manifests applied. It does not prove a single byte moved. This skill moves bytes and then goes looking for them.

## The one thing that makes this work: correlation

Every run mints two ids **before** sending anything:

- `RUN_ID` — an opaque string, carried as `X-Probe-Run` header, `?probe=` query param, and User-Agent.
- `TRACE_ID` — a 32-hex W3C trace id, sent as a `traceparent` header.

**Traefik honours the injected `traceparent` and propagates it to the app** (verified 2026-08-26: the Traefik access log's `TraceId` and the app log's `trace_id` both equal the minted id). So the probe *chooses* its own trace id in advance, and every lens becomes an exact lookup instead of a search:

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

### 1. State what is being investigated

One sentence, before touching anything. It selects the vantage and the lens. "Do sandbox logs reach Loki" and "can the app still resolve DNS under the draft policy" need completely different setups.

### 2. Pick a vantage — how traffic gets sent

| | Mechanism | Use when isolating |
|---|---|---|
| **V1 laptop** | `curl` to `http://<host>.<cluster>.home/...` | the full path: DNS → Traefik → HTTPRoute → Service → pod |
| **V2 port-forward** | `kubectl port-forward` to Service or pod | the app alone, with Traefik removed from the picture |
| **V3 in-pod** | `kubectl debug --target` into the app pod | **egress as the app** — DNS, Mongo, EMQX, LAN UDP, internet. The only correct vantage for NetworkPolicy work |
| **V4 standalone pod** | `kubectl run --rm` with chosen labels | negative tests — what a pod that *should not* reach X can actually reach |

Prefer V3 over V4 when the question is "can this app reach X", because V3 inherits the app pod's network namespace and therefore its exact Cilium identity — a policy verdict from V4 is a verdict about a different pod.

Exact commands, caveats, and the ephemeral-container residue rule: [references/vantages.md](references/vantages.md).

### 3. Pick a target — and check what it actually emits

`/health/live` and `/health/ready` are **useless as probes**: they are excluded from access logging and emit no telemetry. Probing them proves nothing about the observability pipeline.

The endpoint inventory — which paths are safe to call repeatedly, and which signals each one produces — is [references/targets.md](references/targets.md). Read it before choosing. It also carries the URL construction rules and every in-cluster service address.

### 4. Choose a shape

- **single** — one request. Enough for logs/traces.
- **burst** — N requests. Needed before metrics move visibly.
- **sustained** — loop at an interval. Required for Hubble (its ring buffer holds ~60s) and for rate-based PromQL.

### 5. Start the lens BEFORE sending, when the lens is live-capture

Hubble and `cilium monitor` are live streams over a ring buffer that turns over in about a minute on these nodes. Start the follow, *then* send. Loki/Tempo/Prometheus are stores and can be queried afterwards.

### 6. Send

### 7. Verify through the lens

Lenses and their exact, verified queries: [references/lenses.md](references/lenses.md).

- **response** — status, latency, headers. No cluster access needed.
- **telemetry** — Loki, Tempo, Prometheus. Per-signal PASS/MISS **and time-to-appear**.
- **flows** — Hubble verdicts: FORWARDED / DROPPED / AUDIT.
- **drops** — `cilium monitor --type drop`, policy denials.
- **delivery** — did the side effect land: MQTT message, Mongo document, Influx point.

### 8. Report

Report what was observed, per signal, including misses. A miss is a finding, not a failure of the run.

```
Run:     <RUN_ID>   trace <TRACE_ID>
Vantage: V1 laptop → api.server2.home
Target:  GET /iot/interactive-map-feeder/v1/data-sources/list  (production, server2)
Shape:   single

response    PASS  200 in 37ms
loki:traefik PASS  +7s
loki:app     PASS  +7s
tempo        PASS  2 services, 11 spans (traefik → interactive-map-feeder-api)
prometheus   MISS  traefik_service_requests_total unchanged — see gotchas: scrape interval
```

Never report a signal as PASS without having seen the data. If a lens was not run, say "not checked" — not "OK".

## Safety

- **Read-only endpoints by default.** GET only. Anything that writes needs the operator to say so explicitly, per run.
- **Never follow redirects on `qr-manager-api /:slug`** — the redirect target is user-supplied data pointing anywhere. Record `%{redirect_url}`, do not fetch it.
- **Prefer sandbox over production** whenever the question can be answered in either.
- **This skill never applies policy**, never edits manifests, never syncs ArgoCD. It observes. Changes go through git.
- **Clean up.** `kubectl run` always with `--rm`. Sweep for orphaned `probe-*` pods on entry. Ephemeral containers cannot be removed without restarting the pod — see [references/vantages.md](references/vantages.md).
- **Never touch anything holding data** — PVCs, PVs, Longhorn volumes, StatefulSets.
- Traffic is real traffic. It appears in dashboards, counts toward metrics, and is visible to anyone else looking at the cluster.

## Auth

Every endpoint listed today is unauthenticated. Phase 0 hardening will change that. When it does, the credential step goes in [references/targets.md](references/targets.md) — fetched from OpenBao at run time, never committed.

## Before believing a negative result

A MISS has three common innocent explanations before it is a real defect: the lens was started too late, the signal needs more volume than one request, or not enough time has passed. [references/gotchas.md](references/gotchas.md) lists the traps that have actually bitten in this homelab. Read it before declaring something broken.
