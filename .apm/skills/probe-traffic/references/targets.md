# Targets — what to probe, and what each one emits

## Contents

- Choosing a target
- HTTP endpoint inventory
- URL construction
- Non-HTTP targets (V3 / V4 only)
- Expected-flow oracle
- Auth

All custom apps run on server1. Every row below was re-checked against server1 sandbox on
2026-10-06 unless it says otherwise.

## Choosing a target

Pick by **what the probe needs to exercise**, not by what is convenient:

| To test | Use | Anonymous result |
|---|---|---|
| ingress + telemetry pipeline, cheapest and safest | `interactive-map-feeder-api` → `/data-sources/list` | `401` — still full telemetry |
| internet egress / FQDN policy | `interactive-map-feeder-api` → `/data-sources/radar/image` | `401` — **needs a token** to reach CHMI |
| MongoDB reachability from an app | `qr-manager-api` → `/<slug>` | public; `404` for an unknown slug |
| ingress only, no app logic | any Swagger UI (below) | `200` |
| that a pod is alive (nothing else) | `/health/live` — **emits no telemetry** | — |

## HTTP endpoint inventory

Paths are **as the app sees them** — see URL construction below for the externally reachable form.

### interactive-map-feeder-api

| Path | Side effects | Notes |
|---|---|---|
| `GET /data-sources/list` | none — no Mongo, no external call | **The default probe.** Anonymous → `401` in ~20 ms, with Traefik log, app log and trace all present. With a token → `200`, `{"dataSources":["radar"]}` (verified 2026-08-26) |
| `GET /data-sources/<ds>/image` | **calls the CHMI external APIs** | The only way to generate internet egress on demand; **needs a token**. `<ds>` = `radar`. Returns an image — always `-o /dev/null`. Not for bursts: it hits a third party |
| `GET /api/docs/` | none | Swagger UI. Trailing slash matters |

### miot-bridge-api

**No safe non-doc endpoints.** Anything functional touches devices, MQTT, or Mongo.

| Path | Side effects | Notes |
|---|---|---|
| `GET /api/docs/` | none | Swagger UI. Trailing slash matters |
| `GET /commands/docs/` | none | Swagger UI. Trailing slash matters (not re-checked 2026-10-06) |

For miot-bridge egress (MQTT, Mongo, miIO UDP), use **V3 in-pod** and probe the
dependencies directly. Do not try to drive them through the HTTP API.

### qr-manager-api

| Path | Side effects | Notes |
|---|---|---|
| `GET /<slug>` | **reads MongoDB**, responds with a redirect | Public. The Mongo-path probe. **Never follow the redirect** — the target is user-supplied data. Use `-o /dev/null -w '%{http_code} %{redirect_url}'`, no `-L`. An unknown slug returns `404` and still proves Mongo was reached, via the app's own log line |
| `GET /api/docs/` | none | Swagger UI. **Without** the trailing slash it 302s to a URL that has lost the `/iot/qr-manager` prefix |

### knowledge-base-api

Production only — there is no sandbox instance. From the code, 2026-10-17; not re-checked.

| Path | Side effects | Notes |
|---|---|---|
| `GET /status` | reads Postgres | `reader`. Anonymous → `401` |
| `GET /search?q=<question>` | **embeds the question on server2's Ollama**, reads Postgres | `reader`. Exercises the server2 egress path; answers `mode: FULLTEXT` when Ollama is unreachable |
| `POST /reindex` | **starts an indexing run** — `full=true` saturates server2's CPU for ~25 minutes | `admin`. Never a probe |
| `GET /api/docs/` | none | Swagger UI. Trailing slash matters |

### qr-manager-ui

| Path | Side effects | Notes |
|---|---|---|
| `GET /healthz` | none | nginx exact-match location. **Emits nothing** — useless as a telemetry probe |
| `GET /qr-manager/` | none | Static SPA, `200`. `stripPrefix: false`, so the app sees the full prefixed path |

## URL construction

From `gitops/helm-charts/app/templates/httproute.yaml`:

```
https://<component>.<vars.domain>/<pathName>/<app path>
```

| Piece | Where it comes from | Values today |
|---|---|---|
| `component` | `labels.component` in `gitops/helm-values/server1/apps/<app>/values.yaml` | `api` for the APIs · `apps` for qr-manager-ui |
| `vars.domain` | `gitops/helm-values/server1/apps/vars/<env>.yaml` — carries the environment | production: `server1.homelab.irha.cz` · sandbox: `sandbox.server1.homelab.irha.cz` |
| `pathName` | `ingress.pathName` in the app's `values.yaml` | see table |

| App | pathName | stripPrefix |
|---|---|---|
| miot-bridge-api | `iot/miot-bridge` | true |
| interactive-map-feeder-api | `iot/interactive-map-feeder` | true |
| qr-manager-api | `iot/qr-manager` | true |
| knowledge-base-api | `kb/knowledge-base` — production only | true |
| qr-manager-ui | `qr-manager` | **false** |

`stripPrefix: true` means Traefik removes the prefix before the app sees it — which is why the
V1 URL and the V2 port-forward URL differ for the same request.

Worked examples:

```
sandbox     https://api.sandbox.server1.homelab.irha.cz/iot/interactive-map-feeder/data-sources/list
production  https://api.server1.homelab.irha.cz/iot/interactive-map-feeder/data-sources/list
production  https://api.server1.homelab.irha.cz/iot/qr-manager/<slug>
production  https://apps.server1.homelab.irha.cz/qr-manager/
```

Do not hand-assemble a URL that a run depends on without confirming against the values files —
`pathName` already contains the `iot/` segment for the APIs, which is easy to double up.

## Non-HTTP targets (V3 / V4 only)

Addresses as of 2026-10-06 on server1 (`kubectl get svc -A` to re-check):

| Target | Address | Probe |
|---|---|---|
| CoreDNS | `10.96.0.10:53` | `getent hosts mongodb.mongodb.svc.cluster.local` |
| MongoDB | `mongodb.mongodb.svc.cluster.local:27017` | `/dev/tcp`, or `mongosh --eval 'db.runCommand({ping:1})'` |
| EMQX (MQTT) | `emqx.iot.svc.cluster.local:1883` | `/dev/tcp` — no MQTT client in the image |
| Alloy OTLP HTTP | `k8s-monitoring-alloy-receiver.monitoring.svc.cluster.local:4318` | `curl .../v1/traces` — **HTTP 405 on GET means healthy**, it only accepts POST |
| Alloy OTLP gRPC | same host `:4317` | `/dev/tcp` |
| InfluxDB2 | `influxdb2.iot.svc.cluster.local:80` | `curl /health` |
| miIO device (LAN) | a device in `192.168.1.0/24`, UDP `54321` — e.g. `192.168.1.85` | `echo -n probe > /dev/udp/192.168.1.85/54321` |
| CHMI (internet) | `opendata.chmi.cz:443`, `produkty.chmi.cz:443` | `curl -sS -o /dev/null -w '%{http_code}'` |
| miot-spec (internet) | `miot-spec.org:443` | same |
| OpenBao (server3) | `vault.server3.homelab.irha.cz:443` | HTTPS, from server1/server2 via ExternalSecrets |
| Cross-cluster OTLP | `192.168.1.202:4317` / `otel.server3.homelab.irha.cz` | belongs to the `monitoring` namespace, **not** to app pods |

UDP probes prove that **egress was permitted**, never that anything received the packet. There
is no response to observe. For UDP, the lens must be Hubble, not the response.

## Expected-flow oracle

The flow inventory behind the default-deny rollout carries one finding worth bringing into every
probe run:

> Three of the most important flows produce no traffic at all under idle conditions — DNS
> (long-lived connections, resolved at startup), CHMI egress (only during a user request), and
> miIO LAN egress (only with a registered device).

Which is exactly why this skill generates traffic rather than waiting for it.

## Auth

The APIs require a bearer token (the IoT ones since 2026-09-09); anonymous callers get `401` from the app's
auth guard. The app still logs the request with `trace_id` and exports the trace, so an anonymous
probe exercises ingress and the whole telemetry pipeline. It does **not** run the handler, so it
cannot prove internet egress or a Mongo read behind auth.

When the handler must run, ask the operator for a token and pass it through the environment —
never on the command line you show, never in the report:

```bash
curl ... -H "Authorization: Bearer $PROBE_TOKEN" ...
```

The usual source is the operator's `postman` client login (Authorization Code + PKCE, see
`docs/identity.md` § Client-only applications). Tokens carry no refresh token; when one expires,
ask for a new one.
