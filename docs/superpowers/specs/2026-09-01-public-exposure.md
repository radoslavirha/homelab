# Public exposure — putting some services on the internet

**Status:** Analysis. **Deliberately not scheduled.** 2026-09-01. Zone facts measured
2026-09-02 during the TLS spec's stages 0–1 — see [The trap, stated first](#the-trap-stated-first);
they rule Option B out for now.

**Gate:** nothing here happens before Zitadel **T5** — the phase where the APIs actually verify
tokens. See [Publishing a frontend publishes its API](#publishing-a-frontend-publishes-its-api)
for why that is a hard gate and not a preference.

**Sibling:** [`../plans/2026-09-03-tls-remaining-work.md`](../plans/2026-09-03-tls-remaining-work.md), and the completed migration it replaced — HTTPS on
every internal service. That work is independent, unblocked, and comes first. **It also decides
the hostnames, permanently.** This document exists so that decision is made with the endgame in
view, not so any of it gets built now.

**Upstream:** [`iot-miniservers/…/2026-08-30-zitadel-tenancy-topology.md`](../../../../iot-miniservers/docs/superpowers/specs/2026-08-30-zitadel-tenancy-topology.md)
for the T-phases.

---

## The trap, stated first

> **`*.irha.cz` currently resolves to the WAN address**, maintained by UniFi DDNS. Port-forward
> 443 to a cluster's Traefik and **every HTTPRoute on that cluster becomes reachable from the
> internet** — the wildcard resolves any name, and Traefik routes on the `Host` header alone.

On server3 that list is OpenBao, ArgoCD, Longhorn UI, Headlamp, Hubble, Grafana, the Traefik
dashboard and the OTLP receiver. Several have no authentication at all.

This is not a hypothetical. It is the default outcome of the most obvious next step.

**Measured 2026-09-02** (Cloudflare API, whole zone — two records, nothing else):

```
A  irha.cz     100.67.147.18
A  *.irha.cz   100.67.147.18
```

The wildcard is real and live. Two qualifications, both material to what follows.

**The address is CGNAT.** `100.67.147.18` sits in `100.64.0.0/10` — carrier-grade NAT, not a
public address. Nothing on the internet can reach it, so **today the trap is armed but not
loaded**: no port forward on the router can be reachable, and Option B below is not merely
undesirable, it is currently impossible. That is an ISP fact, not a design choice — it can
change without warning if the ISP hands out a real address, and the wildcard would then arm
instantly, at every depth. It is an argument for dropping the wildcard now rather than later.

The zone briefly looked safer than this: until 2026-09-02 a stale DS at the registrar made every
validating resolver `SERVFAIL` the whole zone. That was a fault, not a control, and it had to be
repaired before any certificate could issue — see the
[DNSSEC postmortem](../../postmortems/2026-09-02-irha-cz-dnssec-servfail.md), since fixed.
It is fixed. The wildcard is live.

**The wildcard matches at any depth.** A wildcard in a *zone* is not the single-label wildcard
of a TLS certificate — RFC 4592 synthesises from `*.irha.cz` for any name with no closer node in
the zone, however many labels deep. Measured 2026-09-02, every one of these answers
`100.67.147.18`:

```
zz.irha.cz   a.b.irha.cz   q.w.e.r.irha.cz   api.sandbox.server2.irha.cz   grafana.server3.irha.cz
```

(Those are the names as queried on the day; the cluster hostnames have since moved under
`homelab.irha.cz`, which changes nothing — the wildcard matches those too.)

So the trap is **not** narrowed by the TLS spec's per-cluster naming. Moving services to
`<svc>.server3.irha.cz` puts them further from the apex and no further from the wildcard. Every
name this repo will ever generate is already covered, and so is every name an attacker guesses.

**Therefore: the exposure model must be opt-in per route.** An opt-out model — expose
everything, then add allow-lists — fails open on every HTTPRoute anyone adds afterwards.

---

## Three constraints that decide the shape

### One hostname per service

**Exposure is a DNS and reachability property. It is never a naming property.** A service does
not get a LAN name and a WAN name. It gets one name that resolves differently depending on who
asks — which is exactly what split horizon provides.

```
                    grafana.irha.cz
                          │
        ┌─────────────────┴─────────────────┐
   asks UniFi                          asks Cloudflare
   (laptop on the LAN)                 (phone on mobile data)
        │                                   │
   192.168.1.202                    tunnel / WAN address
        │                                   │
        └──────────► same Traefik ◄─────────┘
                     same certificate
                     same HTTPRoute
                     same Zitadel client
```

The rule is not stylistic. Three things break the moment a service has two hostnames:

| Breaks | Why |
| --- | --- |
| **Zitadel** | One `ExternalDomain` per instance, baked into the discovery document, every endpoint URL, and the **`iss` claim of every token**. Reach it at two names and the browser starts at A while discovery and tokens say B. Multiple external domains per instance are unsupported — that is what *instances* are for, and per the tenancy spec those are System-API-only |
| **Any SPA** | Two hostnames are two **origins**. Cookies, `localStorage` and session state are per-origin, so logged in at A is not logged in at B. Both must be registered as redirect URIs, and the app must still pick one consistently |
| **Certificates** | A second name is a second SAN on every affected certificate, for no benefit |

Consequence: promoting a service from LAN-only to public becomes **one line of exposure config**.
No rename, no new certificate, no Zitadel change, no HTTPRoute change.

### Three clusters, and only one WAN `:443`

WAN `:443` forwards to exactly one internal address. There are three Traefiks — `192.168.1.200`,
`.201`, `.202`. Publishing from more than one cluster has no clean port-forward answer:

| Workaround | Cost |
| --- | --- |
| Forward to server3, proxy onward to server1/server2 | server3 becomes a SPOF for the other clusters' public apps; a cross-cluster plaintext hop or double TLS termination; confusing traces |
| Distinct WAN ports per cluster (`:443`, `:8443`, …) | ugly URLs, and `:8443` is blocked by the app-namespace egress policy from anywhere inside the clusters |
| Publish from one cluster only | Workable, but it is a permanent constraint chosen by accident |

**This, more than any security argument, is what decides the mechanism below.**

### Publishing a frontend publishes its API

The frontends call this repo's APIs **directly from the browser**. `qr-manager-ui` renders
`"apiBaseURL": "{{ VAR_PROTOCOL }}://api.{{ VAR_PUBLIC_DOMAIN }}/iot/qr-manager"`, and the auth
strategy has the SPA attaching its own bearer token per target. There is no proxy in between.

So exposing `qr-manager-ui` necessarily exposes `qr-manager-api`, which today answers
**unauthenticated CRUD**. `miot-bridge-api` is worse: `/command` actuates physical devices.

> **No frontend goes public before T5.**

Zitadel itself may be published earlier — it authenticates its own traffic. This reverses the
naive ordering in which "TLS, then publish" precedes the auth work.

---

## The exposure tiers

| Tier | Hostname shape | UniFi record | Public record | Services |
| --- | --- | --- | --- | --- |
| **LAN-only** | `<svc>.<cluster>.homelab.irha.cz` | yes | **no** | OpenBao, ArgoCD, Longhorn, Headlamp, Hubble, Traefik dashboards, EMQX, InfluxDB2, OTLP, the homelab dashboard |
| **Public** | `<svc>.irha.cz` — apex | yes — the fast path | yes | Zitadel (`auth.`), `qr.`, Grafana, frontends **and their APIs, after T5** |

**As of 2026-09-02 the tier is visible in the hostname.** The TLS spec's
[naming decision](../../architecture.md#hostnames-and-tls)
reserves `homelab.irha.cz` for infrastructure and keeps the apex for the short list above, chosen
from *this* table. So "is this service publishable?" is answered by looking at its name, and a
new HTTPRoute cannot drift into the public tier by accident — it would have to be given an apex
hostname deliberately.

That is a naming convention, not an enforcement mechanism. It makes the opt-in **legible**; the
tunnel ingress list is still what makes it **true**.

Every service keeps its UniFi record regardless of tier. Without one, a LAN client resolves the
public address and hairpins through the router — or, with a tunnel, leaves the house entirely and
comes back, making the home internet connection a dependency for reaching a machine on the same
switch.

There is no useful **WAN-only** tier. Its one argument is making a Cloudflare Access policy
non-bypassable from the LAN, which is not worth the hairpin for a single-operator homelab.

Grafana, if published, needs `grafana.ini: server.root_url` and `domain` set, or deep links and
the image renderer break.

---

## Option A — Cloudflare Tunnel (`cloudflared`)

A pod dials out to Cloudflare; hostnames map to internal services in the tunnel's own ingress
rules.

- No port forward, no inbound firewall rule, no published home address.
- **The allow-list is the config.** A hostname absent from the ingress rules is unreachable no
  matter what DNS says. Opt-in by construction.
- One tunnel per cluster solves the three-cluster problem outright.
- Cloudflare edge brings DDoS protection, and Cloudflare Access could gate a route *in front of*
  Zitadel if that is ever wanted.
- **Cost:** another component to run and upgrade, and Cloudflare terminates TLS and therefore
  sees plaintext — including Zitadel's auth traffic. Reasonable for a homelab, but it should be
  a conscious trade.
- It does **not** replace cert-manager. LAN traffic still terminates on Traefik and still needs
  the certificates from the TLS spec.

### Why a dynamic WAN address is a non-problem here

The obvious objection — "the home address is not static, so how does anything point at it" —
does not apply, because **nothing ever points at the address**.

`cloudflared` dials **outbound** to the Cloudflare edge (QUIC/HTTPS 443, the same direction as a
browser fetching a page) and holds those connections open. Cloudflare identifies the tunnel by
its **credential**, never by source address. The public record is:

```
qr.irha.cz    CNAME    <tunnel-uuid>.cfargotunnel.com    (proxied)
```

`<uuid>.cfargotunnel.com` is permanent, assigned at tunnel creation. When the ISP rotates the
address, the open connections drop, `cloudflared` redials from the new one, and Cloudflare
accepts it on credential. No record changed, because no record ever referenced the address.

Consequences: **DDNS becomes unnecessary for public services entirely**, and this works behind
CGNAT, where port-forwarding cannot work at all.

This is also the answer to *"should ExternalDNS write to Cloudflare too?"* — it would build A
records from the Gateway status address, `192.168.1.202`, and publish a private IP. The tunnel's
record is a CNAME to a stable name: nothing dynamic to track, nothing for ExternalDNS to do.

### Config shape

Use a **locally-managed** tunnel, so the ingress rules live in git rather than the Cloudflare
dashboard, and point them at **Traefik** rather than at backing Services:

```yaml
tunnel: <uuid>
credentials-file: /etc/cloudflared/creds.json
ingress:
  - hostname: auth.irha.cz
    service: https://traefik.traefik.svc.cluster.local:443
    originRequest:
      originServerName: auth.irha.cz
  - hostname: qr.irha.cz
    service: https://traefik.traefik.svc.cluster.local:443
    originRequest:
      originServerName: qr.irha.cz
  - service: http_status:404          # required catch-all
```

- **Through Traefik, not around it.** Every HTTPRoute, the stripPrefix/addPrefix middleware, and
  the Traefik access logs and traces feeding the Grafana dashboards keep working. Pointing at
  Services directly discards all of it.
- `originServerName` sets SNI so Traefik presents and validates the right certificate.
- **The catch-all must be `http_status:404`.** A catch-all pointing at Traefik with no `hostname`
  forwards everything and destroys the opt-in property. The explicit hostname list *is* the
  allow-list.
- Locally-managed tunnels do **not** auto-create the CNAME —
  `cloudflared tunnel route dns <tunnel> <hostname>`, once per hostname, or a proxied CNAME in
  the dashboard. Three to five records, created once.
- Credential to OpenBao → ESO → Secret → mounted file, the same path as every other secret here.
  `replicas: 2`; Cloudflare distributes across replicas of one tunnel.

The UniFi record still answers `192.168.1.202`, so LAN traffic never enters the tunnel. The
tunnel is purely the WAN leg of the split horizon — one that happens to contain no IP address.

---

## Option B — port-forward 443, second Gateway listener

Forward WAN 443 to a **separate** Traefik entrypoint (say `public` on 8443), exposed as a second
listener on the Gateway. A route is public only if it names that listener:

```yaml
parentRefs:
  - name: traefik-gateway
    namespace: traefik
    sectionName: public      # opt-in; everything else stays on `websecure`
```

- Pure Gateway API, no new component, no third party in the auth path.
- **Cost:** the home address is published; the router is the only thing between the internet and
  Traefik; the `*.irha.cz` DDNS wildcard must be **replaced** with a specific DDNS host plus
  explicit records per public name, or the enumeration surface stays wide open; and the
  three-cluster problem above has no clean answer.
- **Blocked outright today.** The WAN address is CGNAT (measured 2026-09-02, above). There is no
  inbound path to forward, so this option cannot be built at all without an ISP change — a
  static or at least non-CGNAT address. Verify that before spending any time here.

---

## Recommendation

**Option A.** The deciding factor is the three-cluster topology — port-forwarding has no clean
way to publish from more than one cluster, and every workaround makes one cluster a SPOF for the
others. Behind that: the allow-list is structural rather than a convention someone must remember
on every new HTTPRoute, and the port forward and published home address both disappear.

Option B remains legitimate *in principle* if keeping Cloudflare out of the auth path is worth
running the allow-list by hand and publishing from one cluster only. **It is not buildable
today** — the WAN address is CGNAT, so there is nothing to forward. That removes the only real
alternative and makes Option A the choice by elimination, not just by preference.

**Either way: drop the `*.irha.cz` DDNS wildcard.** Publish only names that are meant to be
public.

**Done 2026-09-02.** The UniFi DDNS client was removed outright — Option A never needed it, since
a tunnel CNAME references no address. Removing the client left the records it had written behind,
frozen; those were deleted separately. The zone now holds only what someone puts there on
purpose.

---

## Rough order, when the gate opens

Not scheduled. Recorded so the TLS spec's naming decisions can be checked against it.

1. Zitadel T0–T3 on LAN-resolvable HTTPS hostnames — unblocked by the TLS spec's stage 4
2. Publish **Zitadel and `qr.irha.cz` only**. The DDNS wildcard is already gone as of 2026-09-02
3. Zitadel T5 — the APIs verify tokens
4. Publish the frontends **and the APIs they call**. Not before step 3

---

## Open — verify before building any of this

- [ ] **UniFi DDNS wildcard removal.** What can the UniFi DDNS client actually be told to update? If only a wildcard, the public-record plan changes. Cheap to check now — it is step 1.4 of the TLS spec.
      **Partially answered 2026-09-02:** the zone shows the client currently maintaining *both*
      `irha.cz` and `*.irha.cz`, so it writes at least two targets. Whether it can be narrowed to
      a specific hostname is still unread — that has to come from the UniFi UI, not the zone
- [ ] **Cloudflare Tunnel and Zitadel forwarded headers.** Zitadel builds absolute URLs from the request; `X-Forwarded-Proto` and `Host` must arrive intact or redirects come back as `http://`
- [ ] **Tunnel → Traefik over HTTPS with `originServerName`.** Confirm Traefik serves the right certificate by SNI on that path and that the hop validates
- [ ] **Whether Cloudflare terminating TLS on auth traffic is acceptable.** A judgement call, not a technical one, but it should be made explicitly rather than by default
- [ ] **Grafana `root_url` / `domain`** before publishing it, or deep links and the image renderer break
