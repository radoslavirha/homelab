# Lenses — how to see what the traffic produced

Pick per investigation. They are independent; run one or several. Queries below were executed
against the live stack on 2026-08-26 and returned the data shown.

---

## Lens: response

The cheapest lens, and the only one needing no cluster access. Often sufficient.

```bash
curl -sS -o /dev/null \
  -w 'http=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s redirect=%{redirect_url}\n' \
  ... URL
```

The split timings localise a failure before any query runs: `dns=` implicates
ExternalDNS/Unifi, `connect=` implicates Traefik or the node, a large gap between `connect=`
and `ttfb=` implicates the app or its dependencies.

To confirm the trace id was actually propagated rather than assumed, dump response headers with
`-D -`.

---

## Lens: telemetry

Grafana MCP, against server3. Datasource UIDs: `loki`, `prometheus`, `tempo`,
`influxdb2-server1`, `influxdb2-server2`.

### Loki

Index labels are the **OTel** names, because Alloy ships logs over Loki's native OTLP endpoint:
`k8s_cluster_name`, `k8s_namespace_name`, `k8s_pod_name`, `k8s_container_name`, `service_name`,
`service_namespace`. Plain `cluster` exists only as structured metadata — a stream selector on
`cluster=` matches nothing.

Traefik access log for the run:

```logql
{k8s_cluster_name="server2", k8s_namespace_name="traefik"} |= "<RUN_ID>"
```

App log for the run — `trace_id` is structured metadata, so this is an exact, cheap filter:

```logql
{k8s_cluster_name="server2", k8s_namespace_name="production"} | trace_id="<TRACE_ID>"
```

Always include a selective label matcher and a narrow time range (`now-15m`). A bare
`{k8s_cluster_name="server2"}` scans every stream on the cluster.

What a healthy result looks like — Traefik emits a JSON access log carrying `RequestPath` with
the `?probe=` param, `ServiceName`, `ServiceAddr` (the actual pod IP), `DownstreamStatus`,
`OriginDuration`, and `TraceId`. The app emits its own line with `trace_id`, `span_id`, the
echoed `x-probe-run` header, and `service_version` in structured metadata.

Observed lag: **~7 s** from request to queryable in Loki. Retry to a ~90 s deadline before
calling it a MISS, and report the time-to-appear — a signal arriving at 60 s is a finding even
though it is a PASS.

### Tempo

Fetch the exact trace by the id the probe minted. No TraceQL search, no time-range guessing:

```
mcp__grafana__grafana_api_request
  endpoint: /api/datasources/proxy/uid/tempo/api/traces/<TRACE_ID>
  jq: [.batches[]? | {svc: (.resource.attributes[]? | select(.key=="service.name") | .value.stringValue),
                      spans: [.scopeSpans[]?.spans[]? | .name]}]
```

Healthy result for the default probe — two services, the chain visible end to end:

```json
[{"svc":"interactive-map-feeder-api","spans":["middleware - …","request handler - /v1/data-sources/list","GET /v1/data-sources/list"]},
 {"svc":"traefik","spans":["GET","GET"]}]
```

Read it as: **traefik present but app absent** → the app's OTLP export is broken, or its egress
to `alloy-receiver:4318` is blocked. **App present but traefik absent** → Traefik's own tracing
export is broken. **Both absent, HTTP was 200** → suspect the collector or Tempo itself, not
either app.

When building Tempo-backed dashboard panels, do not `select()` numeric span attributes — it
crashes table panels. String attributes are safe.

### Prometheus

Nothing is scraped from the apps — they push OTLP. These are the metric families that exist,
with their real labels:

| Metric | Source | Labels that matter |
|---|---|---|
| `traefik_service_requests_total` | Traefik | `k8s_cluster_name`, `service`, `code`, `method` |
| `traefik_router_requests_total` | Traefik | same shape |
| `http_server_request_duration_seconds_count` | Traefik OTLP | `k8s_cluster_name`, `server_address`, `http_request_method`, `http_response_status_code` |
| `traces_spanmetrics_calls_total` | Tempo metrics generator | `k8s_cluster_name`, `service`, `span_name`, `span_kind`, `status_code` |
| `http_client_request_duration_seconds` | the apps themselves | `server_address` — a per-destination record of outbound calls, ~30 d retention |

`service` on `traefik_service_requests_total` is the long gateway name, e.g.
`production-api-iot-interactive-map-feeder-api-http-http-80@kubernetesgateway`. Copy it from the
`ServiceName` field of the Loki access log rather than constructing it.

Counter delta around a burst:

```promql
increase(traefik_service_requests_total{k8s_cluster_name="server2", code="200"}[5m])
```

A single request will often not move a rate visibly. Send a burst, or use the raw counter and
compare a before/after reading. `http_client_request_duration_seconds{server_address=...}` is
the tool for "has this app ever called that host", including for flows too rare for Hubble.

---

## Lens: flows (Hubble)

**Start the follow before sending traffic.** The ring buffer holds ~4095 events per node against
roughly 4000 flows/minute, so it turns over in about a minute — `--last N` buys essentially no
history.

```bash
export KUBECONFIG=iac/clusters/server2/credentials/kubeconfig

# background follow, then send
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --follow --namespace production --pod api-iot-interactive-map-feeder-api > /tmp/flows.txt &
```

Useful filters: `--namespace`, `--pod`, `--to-port 27017`, `--protocol udp`,
`--verdict DROPPED,AUDIT`, `--type drop`.

Reading the output — on these clusters, **all ingress to app pods arrives from the node's
`cilium_host`** (`10.244.0.186` on server2, `10.244.0.188` on server1). Both kubelet probes and
Traefik share that identity, because Traefik is hostNetwork. A flow labelled `(host)` is
therefore ambiguous between the two; separate them by port and by correlating with the Traefik
access log, not by source.

Sample of a healthy forward:

```
10.244.0.186:54626 (host) -> production/apps-iot-qr-manager-ui-…:80 (ID:43830) to-endpoint FORWARDED (TCP Flags: ACK)
```

`ds/cilium` addresses one agent, which is fine only because server1 and server2 are single-node.
On a multi-node cluster, follow on the node running the target pod.

---

## Lens: drops

For NetworkPolicy work. Two complementary views:

```bash
# policy verdicts, including audit-mode ones
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --follow --verdict DROPPED,AUDIT

# datapath drops with reasons
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor --type drop
```

`AUDIT` verdicts are what Stage 2 of the default-deny rollout produces: the packet is allowed,
but Cilium records that a policy *would* have denied it. A clean audit log over a full day — not
a quiet 18 minutes — is the gate before Stage 3.

A policy that selects a pod switches that pod's direction to deny-by-default in Cilium's
`default` enforcement mode. The draft allowlist in
`gitops/k8s-manifests/server2/network-policies/DRAFT/` is therefore **one atomic unit**;
applying `20-allow-egress-in-cluster.yaml` alone denies DNS immediately. This skill does not
apply any of it.

---

## Lens: delivery

Did the side effect actually land. V3 or V4 vantage, using the probe image's clients.

```bash
# Mongo — connectivity and a read-back
mongosh "mongodb://<user>:<pass>@mongodb.mongodb.svc.cluster.local:27017/<db>" \
  --quiet --eval 'db.runCommand({ping:1})'

# InfluxDB2
influx query 'from(bucket:"<bucket>") |> range(start:-5m) |> limit(n:5)' \
  --host http://influxdb2.iot.svc.cluster.local:80 --org homelab --token "$TOKEN"
```

There is no MQTT client in the probe image, so EMQX delivery cannot be verified from a probe
pod — only TCP reachability to `:1883`. To check MQTT end to end, use the EMQX dashboard
(`emqx.<cluster>.home`) or subscribe from the laptop against the Traefik TCP entrypoint
(`192.168.1.201:1883` on server2).

Credentials live in OpenBao and reach the clusters as ExternalSecrets. Read them from a running
pod's environment or from OpenBao with `bao` — never hardcode, never echo into run output.
