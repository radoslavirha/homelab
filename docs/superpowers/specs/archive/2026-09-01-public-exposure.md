# Public exposure — the remaining work

**Status:** **DONE and archived 2026-09-22.** `auth.irha.cz`, `grafana.irha.cz` and
`mealie.irha.cz` are published through Cloudflare Tunnels and verified end to end. Kept as the
design record: why a tunnel rather than a port-forward or a VPN, why one hostname per service, why
the allow-list is a config file rather than DNS.

**The working reference is [`docs/public-exposure.md`](../../public-exposure.md)** — read that to
publish a service. This file explains the reasoning; it is not a runbook and is not maintained.

**What this document got wrong, worth keeping:** it asserted for three weeks that the house had a
routable address, on the strength of an egress-IP measurement. Egress IP is the carrier's NAT
address, not yours. The correct test compares the router's own WAN address with the egress
address, or reads hop 2 of a traceroute. That error survived two rounds of "verification" and
changed two decisions before it was caught.

## The decision: where TLS terminates

| | **Option A — Cloudflare Tunnel** | **Option B — port-forward 443** |
| --- | --- | --- |
| Inbound firewall rule | none | WAN `:443` to one Traefik |
| Home address published | no | yes |
| Allow-list | **structural** — a hostname absent from the tunnel ingress is unreachable whatever DNS says | by hand, per HTTPRoute, forever |
| Three clusters | one tunnel each, solved | no clean answer (below) |
| Who sees decrypted auth traffic | **Cloudflare** | nobody but you |
| New component to run and upgrade | `cloudflared` | none |

**Recommendation: Option A**, on the three-cluster argument. WAN `:443` forwards to exactly one
internal address, and there are three Traefiks — `192.168.1.200`, `.201`, `.202`. Every workaround
is worse than the problem: forwarding to server3 and proxying onward makes server3 a SPOF for the
other clusters' public apps; distinct WAN ports give ugly URLs and `:8443` is blocked by the
app-namespace egress policy; publishing from one cluster only is a permanent constraint chosen by
accident.

**The real cost of Option A, stated plainly so it is chosen and not defaulted into:** Cloudflare
terminates TLS, so the edge sees plaintext — including every credential posted to `auth.irha.cz`.
Option B's single genuine advantage is that this is not true of it. That is a judgement about who
you trust, not a technical question, and it is what this document is waiting on.

---

## Invariants — true under either option

### One hostname per service

A service gets **one** name that resolves differently depending on who asks. Split horizon already
does this: UniFi answers `192.168.1.20x` on the LAN, the public record answers the edge.

```
                    grafana.irha.cz
        ┌─────────────────┴─────────────────┐
   asks UniFi (LAN)              asks Cloudflare (mobile)
   192.168.1.202                      tunnel / WAN
        └──────────► same Traefik ◄─────────┘
              same cert, route, OIDC client
```

Two hostnames break three things at once: Authentik's `iss` claim is anchored to one external
name; two hostnames are two browser **origins**, so logged in at one is not logged in at the
other; and the second name is another SAN on every affected certificate, for no benefit.

**Consequence: promoting a service to public is one line of exposure config.** No rename, no new
certificate, no Authentik change, no HTTPRoute change.

**Every service keeps its UniFi record**, public or not. Without one a LAN client hairpins through
the router — or, with a tunnel, leaves the house and comes back, making the home internet
connection a dependency for reaching a machine on the same switch.

### Publishing a frontend publishes its API

The SPAs call the APIs **directly from the browser** — `qr-manager-ui` renders
`"apiBaseURL": "…/iot/qr-manager"` and attaches its own bearer token per target. No proxy in
between. Authentication is no longer the problem; **authorization is**: only `miot-bridge`'s
`CommandController` carries `@RequireRoles`, so six other controllers accept any token a trusted
issuer minted for that audience. See
[`2026-09-22-api-token-verification.md`](2026-09-22-api-token-verification.md).

> **No API hostname is published while a `postman` token carrying no application role can drive
> it.**

The APIs have no apex hostname today, so this is not a live exposure — it becomes one the moment
someone adds one. `qr.irha.cz` is redirect-only (an `addPrefix /r` middleware) and reaches no API.

### Exposure is opt-in per name, never opt-out

An opt-out model — publish, then add allow-lists — fails open on every HTTPRoute anyone adds
later. Under Option A the tunnel ingress list is the allow-list; under Option B it is the
`sectionName` on each route.

---

## The tiers

| Tier | Hostname | UniFi record | Public record | Services |
| --- | --- | --- | --- | --- |
| **LAN-only** | `<svc>.<cluster>.homelab.irha.cz` | yes | **no** | OpenBao, ArgoCD, Longhorn, Headlamp, Hubble, Traefik dashboards, EMQX, InfluxDB2, Ollama, OTLP, the homelab dashboard |
| **Public** | `<svc>.irha.cz` — apex | yes | opt-in, per name | live apex names 2026-09-22: `auth.`, `qr.`, `grafana.`, `mealie.`, `assistant.` — all LAN-only until published |

The tier is visible in the hostname, so "is this publishable?" is answered by reading the name,
and a new HTTPRoute cannot drift into the public tier by accident. That is legibility, not
enforcement — the allow-list is what makes it true.

There is no **WAN-only** tier. Its one argument is making a Cloudflare Access policy
non-bypassable from the LAN, which is not worth the hairpin for a single-operator homelab.

---

## Work, in order

### 0. Decide TLS termination

Blocking. Everything below assumes Option A; under Option B, step 1's value changes and step 2's
mechanism becomes a Gateway listener plus a router rule.

### 1. Make the client IP survive the edge

**No entrypoint sets `forwardedHeaders.trustedIPs` today, and that is correct while LAN-only:**
Traefik trusts no `X-Forwarded-*` from anyone and rewrites them from the TCP peer, so services see
the real client. **A proxy in front inverts this** — every request appears to come from the proxy.
Two things break together: Authentik's reputation policy would key on one address (a house-wide
lockout bucket, which is why it ships `check_ip: false`), and the `authentik-account-lockout`
alert's `for_ip` would name the tunnel instead of the attacker.

```yaml
# gitops/helm-values/traefik.yaml — on the PUBLIC entrypoint only
ports:
  websecure:
    port: 443
    forwardedHeaders:
      trustedIPs:
        - <the immediate peer's CIDR>
```

**The trusted value is the immediate peer, not Cloudflare's published edge ranges.** With
`cloudflared` running in-cluster the peer is its **pod** IP, so the value is the pod CIDR —
measure it, do not assume the Talos default. Under Option B there is no proxy and the list stays
empty.

Prefer a **separate public entrypoint**, so the LAN entrypoint keeps trusting nobody.

Three things move in the same change, or it is worse than not doing it:

- **Authentik has its own trust list.** Traefik trusting the peer is not enough; Authentik must
  trust Traefik, or `check_ip: true` keys off the wrong address. Confirm the exact setting name
  against the 2026.8 documentation — nothing of the sort is configured in
  `gitops/helm-values/server3/authentik.yaml` today.
- **The Ollama `ipAllowList` middleware** records in its own comment that it works *because* the
  entrypoint trusts nothing. Re-check its `ipStrategy`, or a forged header walks through an
  allow-list.
- **Never `forwardedHeaders.insecure: true`** on a public entrypoint. It lets any client declare
  its own source IP, defeating the allow-list and the reputation policy in one line.

Verify the rendered static config actually carries the key — read it out of the pod, not from
`helm template`. A mistyped key here has been silently discarded by this chart before.

### 2. Stand up the edge

A **locally-managed** tunnel, so the ingress rules live in git rather than the Cloudflare
dashboard, pointed at **Traefik** rather than at backing Services:

```yaml
tunnel: <uuid>
credentials-file: /etc/cloudflared/creds.json
ingress:
  - hostname: auth.irha.cz
    service: https://traefik.traefik.svc.cluster.local:443
    originRequest:
      originServerName: auth.irha.cz
  - service: http_status:404          # required catch-all
```

- **Through Traefik, not around it** — every HTTPRoute, middleware, access log and trace keeps
  working. Pointing at Services discards all of it.
- `originServerName` sets SNI so Traefik presents and validates the right certificate.
- **The catch-all must be `http_status:404`.** A catch-all pointing at Traefik with no `hostname`
  forwards everything and destroys the opt-in property. The explicit hostname list *is* the
  allow-list.
- Locally-managed tunnels do not auto-create the CNAME:
  `cloudflared tunnel route dns <tunnel> <hostname>`, once per name.
- Credential via OpenBao → ESO → Secret → mounted file, like every other secret here.
  `replicas: 2`; Cloudflare distributes across replicas of one tunnel.
- It does **not** replace cert-manager. LAN traffic still terminates on Traefik.

The public record is a CNAME to `<uuid>.cfargotunnel.com`, which is permanent. Nothing ever
references the WAN address, so a dynamic address is a non-problem — and ExternalDNS has nothing to
do here, since it would build an `A` record from the Gateway status and publish `192.168.1.202`.

### 3. Prove the alert path before it is needed

One test notification through `slack-irha-homelab`. The channel is provisioned and verified live,
but nothing has ever fired through it — configuration correct is not the same as webhook valid,
and a published login page is the worst moment to find out.

### 4. Publish `auth.irha.cz` first, alone

**The ordering is forced:** Grafana, Mealie and Open WebUI all redirect to `auth.irha.cz` to log
in. Publish any of them first and off-LAN login dies at the redirect. Authentik also authenticates
its own traffic, so it is the safest thing to expose first.

Then one at a time, each proven before the next: `grafana.` → `mealie.` → `assistant.` → `qr.`

### 5. Per-name checklist

Run all of it for each name before adding the next:

- [ ] Log in from **off-LAN** (mobile data, not the house wifi) — the full redirect round trip
- [ ] From the LAN, confirm traffic still goes direct: UniFi answers `192.168.1.20x`, not the edge
- [ ] `X-Forwarded-Proto` and `Host` arrive intact — Authentik builds absolute URLs from them, and
      a redirect coming back as `http://` is the symptom that they did not
- [ ] The Authentik event log shows the **real client IP**, not the tunnel's
- [ ] Deliberately fail five logins: confirm the lockout fires, reaches Slack, and names the right
      IP — then clear the reputation entry
- [ ] Nothing else became reachable: probe two LAN-only names (`argocd.`, `vault.`) from off-LAN
      and expect failure

---

## Out of scope

- **Cloudflare Access** in front of Authentik. Possible later; it is a second login, not a
  replacement for this one.
- **SMTP.** The zone has no `MX`/`SPF`/`DMARC`, and enrolment and recovery are both admin-minted
  links. Deferred, not rejected.
- **Publishing any API hostname.** Gated on role floors — see the invariant above.

## Open questions

- [ ] **Is Cloudflare terminating TLS on auth traffic acceptable?** Everything waits on it.
- [ ] **Tunnel → Traefik over HTTPS with `originServerName`** — confirm Traefik serves the right
      certificate by SNI on that path, and that the hop validates.
- [ ] **The exact Authentik setting for trusting a proxy's forwarded headers**, and whether
      `check_ip: true` is worth turning on once it is set.
- [ ] **The pod CIDR on the cluster running `cloudflared`** — measure it; do not assume the Talos
      default.
