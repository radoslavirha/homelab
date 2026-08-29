# Targets — what to probe, and what each one emits

## Choosing a target

Pick by **what the probe needs to exercise**, not by what is convenient:

| To test | Use |
|---|---|
| ingress + telemetry pipeline, cheapest and safest | `interactive-map-feeder-api` → `/v1/data-sources/list` |
| internet egress / FQDN policy | `interactive-map-feeder-api` → `/v1/data-sources/radar/image` |
| MongoDB reachability from an app | `qr-manager-api` → `/<slug>` |
| ingress only, no app logic | any `/…/docs` Swagger UI |
| that a pod is alive (nothing else) | `/health/live` — **emits no telemetry** |

## HTTP endpoint inventory

Supplied by the operator, 2026-08-26. Paths are **as the app sees them** — see URL construction
below for the externally reachable form.

### interactive-map-feeder-api

| Path | Side effects | Notes |
|---|---|---|
| `GET /v1/data-sources/list` | none — no Mongo, no external call | **The default probe.** Verified: 200, `{"dataSources":["radar"]}`, ~37 ms end-to-end from the laptop |
| `GET /v1/data-sources/<ds>/image` | **calls the CHMI external APIs** | The only way to generate internet egress on demand. `<ds>` = `radar`. Returns an image — always `-o /dev/null`. Not for bursts: it hits a third party |
| `GET /v1/docs` | none | Swagger UI |

### miot-bridge-api

**No safe non-doc endpoints.** Anything functional touches devices, MQTT, or Mongo.

| Path | Side effects | Notes |
|---|---|---|
| `GET /api/docs/` | none | Swagger UI. Trailing slash matters |
| `GET /commands/docs/` | none | Swagger UI. Trailing slash matters |

For miot-bridge egress (MQTT, Mongo, miIO UDP, Loxone UDP), use **V3 in-pod** and probe the
dependencies directly. Do not try to drive them through the HTTP API.

### qr-manager-api

| Path | Side effects | Notes |
|---|---|---|
| `GET /<slug>` | **reads MongoDB**, responds with a redirect | The Mongo-path probe. **Never follow the redirect** — the target is user-supplied data. Use `-o /dev/null -w '%{http_code} %{redirect_url}'`, no `-L`. Needs a slug that exists; an unknown slug still proves Mongo was reached, via the app's own log line |
| `GET /api/docs` | none | Swagger UI |

### qr-manager-ui

| Path | Side effects | Notes |
|---|---|---|
| `GET /healthz` | none | nginx exact-match location. **Emits nothing** — useless as a telemetry probe |
| `GET /qr-manager/` | none | Static SPA. `stripPrefix: false`, so the app sees the full prefixed path |

## URL construction

From `gitops/helm-charts/iot-applications/templates/httproute.yaml`:

```
http://[<VAR_SUBDOMAIN>.]<component>.<VAR_PUBLIC_DOMAIN>/<pathName>/<app path>
```

| Piece | Where it comes from | Values today |
|---|---|---|
| `VAR_SUBDOMAIN` | `gitops/helm-values/apps/common/<env>.yaml` | production: unset · sandbox: `sandbox.` |
| `component` | `labels.component` in `gitops/helm-values/apps/<app>/base.yaml` | `api` for the three APIs · `apps` for qr-manager-ui |
| `VAR_PUBLIC_DOMAIN` | `gitops/helm-values/<cluster>/apps/common/values.yaml` | `server1.home` · `server2.home` |
| `pathName` | `ingress.pathName` in the app's `base.yaml` | see table |

| App | pathName | stripPrefix |
|---|---|---|
| miot-bridge-api | `iot/miot-bridge` | true |
| interactive-map-feeder-api | `iot/interactive-map-feeder` | true |
| qr-manager-api | `iot/qr-manager` | true |
| qr-manager-ui | `qr-manager` | **false** |

`stripPrefix: true` means Traefik removes the prefix before the app sees it — which is why the
V1 URL and the V2 port-forward URL differ for the same request.

Worked examples:

```
production  server2  http://api.server2.home/iot/interactive-map-feeder/v1/data-sources/list
sandbox     server2  http://sandbox.api.server2.home/iot/interactive-map-feeder/v1/data-sources/list
production  server1  http://api.server1.home/iot/qr-manager/<slug>
production  server2  http://apps.server2.home/qr-manager/
```

Do not hand-assemble a URL that a run depends on without confirming against the values files —
`pathName` already contains the `iot/` segment for the APIs, which is easy to double up.

## Non-HTTP targets (V3 / V4 only)

| Target | Address | Probe |
|---|---|---|
| CoreDNS | `10.96.0.10:53` | `getent hosts mongodb.mongodb.svc.cluster.local` |
| MongoDB | `mongodb.mongodb.svc.cluster.local:27017` | `/dev/tcp`, or `mongosh --eval 'db.runCommand({ping:1})'` |
| EMQX (MQTT) | `emqx.iot.svc.cluster.local:1883` | `/dev/tcp` — no MQTT client in the image |
| Alloy OTLP HTTP | `k8s-monitoring-alloy-receiver.monitoring.svc.cluster.local:4318` | `curl .../v1/traces` — **HTTP 405 on GET means healthy**, it only accepts POST |
| Alloy OTLP gRPC | same host `:4317` | `/dev/tcp` |
| InfluxDB2 |  `influxdb2.iot.svc.cluster.local:80` | `curl /health` |
| miIO device (LAN) | `192.168.1.85:54321` UDP | `echo -n probe > /dev/udp/192.168.1.85/54321` |
| Loxone (LAN) | `192.168.1.140:50450` UDP | same form |
| CHMI (internet) | `opendata.chmi.cz:443`, `intranet.chmi.cz:443` | `curl -sS -o /dev/null -w '%{http_code}'` |
| miot-spec (internet) | `miot-spec.org:443` | same |
| OpenBao (server3) | `vault.server3.home:80` | plain HTTP, from server1/server2 via ExternalSecrets |
| Cross-cluster OTLP | `192.168.1.202:4317` / `otel.server3.home` | belongs to the `monitoring` namespace, **not** to app pods |

UDP probes prove that **egress was permitted**, never that anything received the packet. There
is no response to observe. For UDP, the lens must be Hubble, not the response.

## Expected-flow oracle

`docs/superpowers/plans/2026-08-25-network-default-deny.md` holds the verified flow inventory
for production and sandbox on both clusters, with the evidence class behind every row. Use it as
the expected-result table for policy work instead of restating it here. Its central finding is
worth carrying into every probe run:

> Three of the most important flows produce no traffic at all under idle conditions — DNS
> (long-lived connections, resolved at startup), CHMI egress (only during a user request), and
> miIO LAN egress (only with a registered device).

Which is exactly why this skill generates traffic rather than waiting for it.

## Auth

Every endpoint above is unauthenticated as of 2026-08-26. Phase 0 hardening
(`iot-miniservers` → `docs/superpowers/OPEN-THREADS.md`, where Phase 0 was closed out) will change
that. When it lands, add the credential step here: fetch from OpenBao at run time with the `bao`
CLI already in the probe image, pass as a header, never commit a token and never echo one into
run output.
