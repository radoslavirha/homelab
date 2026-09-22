# Public exposure

How a service in this homelab becomes reachable from the internet, and what must be true before
it is. The design decisions behind this live in
[`superpowers/specs/archive/2026-09-01-public-exposure.md`](superpowers/specs/archive/2026-09-01-public-exposure.md)
and [`superpowers/specs/archive/2026-09-22-exposure-edge-decision.md`](superpowers/specs/archive/2026-09-22-exposure-edge-decision.md);
this document is the working reference.

## What is published today

| Name | Cluster | Tunnel | Published |
|------|---------|--------|-----------|
| `auth.irha.cz` | server3 | `homelab-server3` | 2026-09-22 |
| `grafana.irha.cz` | server3 | `homelab-server3` | 2026-09-22 |
| `mealie.irha.cz` | server1 | `homelab-server1` | 2026-09-22 |

Everything else is LAN-only, including every `*.homelab.irha.cz` name, every API, and the apex
names that exist but have no public DNS record.

## How it works

```
   phone on mobile data                     laptop on the LAN
            │                                       │
   DNS: Cloudflare                          DNS: UniFi (192.168.1.1)
            │                                       │
   Cloudflare edge  ── TLS terminates here          │  answers 192.168.1.20x
            │                                       │
   cloudflared pod (dials OUT, no inbound port)     │
            │                                       │
            └────────────►  Traefik  ◄──────────────┘
                              │
                        same HTTPRoute, same certificate, same OIDC client
```

**One hostname per service.** A service is never given a separate public name; the same name
resolves differently depending on who asks. Two hostnames would break Authentik's `iss` claim,
split the browser origin (logged in at one is not logged in at the other), and add a SAN to a
certificate for nothing.

**The tunnel dials outbound.** The house has no reachable inbound port — the ISP puts it behind
carrier NAT, so a port-forward or any listener on the router cannot work at any price worth
paying. `cloudflared` opens connections outward and Cloudflare routes to them, which sidesteps
that entirely and keeps the home address unpublished.

**One tunnel per cluster.** A tunnel reaches one cluster's Traefik. Sharing one would make a
cluster a dependency of another cluster's public names.

**Traffic goes through Traefik, not around it.** The tunnel points at
`https://traefik.traefik.svc.cluster.local:443` with `originServerName` for SNI, so every
HTTPRoute, middleware, access log and trace keeps working. Pointing at a backing Service directly
would discard all of it.

**Cloudflare terminates TLS**, so the edge sees plaintext — including credentials posted to
`auth.irha.cz`. That is an accepted trade, not an oversight: the alternatives under carrier NAT
all cost money (a public IPv4 add-on, or a VPS you run and patch yourself). The certificate a
public visitor sees is Cloudflare's; cert-manager still serves the LAN and the tunnel hop.

## The allow-list is a ConfigMap, not DNS

`ConfigMap.cloudflared.yaml` in each cluster's `cloudflared` directory is what makes a hostname
reachable. cloudflared refuses any `Host` it does not name, so a DNS record for an unlisted name
returns Cloudflare error 1033 instead of a service.

```yaml
ingress:
  - hostname: auth.irha.cz
    service: https://traefik.traefik.svc.cluster.local:443
    originRequest:
      originServerName: auth.irha.cz
  - service: http_status:404      # MUST be last, MUST be http_status:404
```

**The catch-all is load-bearing.** A catch-all pointing at Traefik with no `hostname` forwards
everything and publishes every HTTPRoute on that cluster in one line — Longhorn, Hubble, the
Traefik dashboard, the APIs. Verified 2026-09-22: a request to the edge with a forged `Host` for
an unlisted name gets `530`, never a service.

## Publishing a new service

Order matters. Steps 1–2 are reversible by deleting a file; step 4 is the moment the name is
public.

**1. Confirm the prerequisites below are all true for that service.**

**2. Trust the client IP on that cluster, if it is not already set.** Per-cluster file, never the
shared one:

```yaml
# gitops/helm-values/<cluster>/traefik.yaml
ports:
  websecure:
    forwardedHeaders:
      trustedIPs:
        - 10.244.0.0/16     # the POD CIDR -- cloudflared runs in-cluster
```

Set on server1 and server3. **Deliberately absent on server2**, whose Ollama `ipAllowList`
middleware works precisely because no entrypoint trusts forwarded headers — putting this in the
shared values file would let any pod there forge a client IP past that allow-list. If server2 ever
needs a tunnel, add the key to *its* per-cluster file and revisit that middleware's `ipStrategy`
in the same change.

The trusted value is the **immediate peer**, which is the cloudflared *pod* — not Cloudflare's
published edge ranges, which is the usual wrong guess. Never `forwardedHeaders.insecure: true`:
that trusts forged headers from anyone and defeats the reputation policy and every allow-list at
once.

**3. Add the hostname block** above the catch-all, commit, push. Stakater Reloader rolls the
cloudflared pods; cloudflared reads its config only at startup. Values-only changes need a hard
refresh before ArgoCD notices:

```bash
kubectl --context admin@server3 -n argocd annotate application cloudflared-<cluster> \
  argocd.argoproj.io/refresh=hard --overwrite
```

**4. Create the public record.** This is the publishing moment:

```bash
cloudflared tunnel route dns homelab-<cluster> <name>.irha.cz
```

It creates a **proxied** CNAME to `<tunnel-uuid>.cfargotunnel.com`. Proxied (orange) is required —
the traffic is HTTP through Cloudflare's edge.

**5. Verify** with the checklist below.

## Prerequisites — all must be true

| | Why |
|---|---|
| The name is in the **apex tier** (`<svc>.irha.cz`) and on its cluster's certificate SAN list | `homelab.irha.cz` names are LAN-only by definition |
| The service **authenticates its own traffic** | Publishing a frontend publishes whatever it calls |
| If it is a frontend, **the API it calls is not published** | The SPAs call APIs directly from the browser, so publishing a frontend publishes whatever it calls. The APIs verify tokens and carry the roles they need — see `identity.md` — but none has an apex hostname, and none needs one yet |
| `auth.irha.cz` is already published | Everything redirects there to log in |
| Absolute-URL settings name the public hostname | e.g. Grafana's `root_url` and `server.domain` |
| The alert path works | A published login page is when you find out it does not |

## Verification checklist

Run all of it per name, from **mobile data with wifi off** — on the LAN, UniFi answers the private
address and you never touch Cloudflare, so a home browser cannot test this.

- [ ] Public DNS resolves to Cloudflare: `dig @1.1.1.1 +short <name>.irha.cz`
- [ ] Log in end to end, including MFA
- [ ] Redirects carry `https` and the public host — a redirect coming back as `http://` means
      `X-Forwarded-Proto` was lost
- [ ] Authentik's event log shows the **real client IP**, not a pod or a Cloudflare address
- [ ] LAN path unchanged: from the LAN the name still answers from `192.168.1.20x`
- [ ] Nothing else became reachable: `dig @1.1.1.1` a LAN-only name and expect no answer
- [ ] Five deliberate wrong passwords produce a lockout, a Slack alert naming the right account
      and address, then clear the reputation entry (`identity.md` § Login surface)

## Un-publishing

Delete the DNS record, then remove the hostname block. Either alone is enough to stop traffic —
the record leaves the name resolving to a tunnel that refuses it (1033), the block leaves a
record pointing at nothing useful. Do both.

## Things that will catch you out

- **You cannot test from home.** Split horizon means the LAN answer wins. Mobile data, wifi off.
- **cloudflared has no reload.** Config changes reach it by pod restart, supplied by Reloader.
- **ArgoCD's Synced badge lies on values-only commits.** Hard refresh, then read the rendered
  container args rather than trusting `helm template`.
- **A client can arrive over IPv6** even though this house has none — Cloudflare's edge is
  dual-stack, and the client address that reaches Authentik may be a v6 one. Nothing in the chain
  may assume IPv4.
- **The pod CIDR is trusted, so any pod on that cluster could forge `X-Forwarded-For`** toward
  Traefik. Accepted because pinning cloudflared's pod IPs breaks on every reschedule. If a cluster
  ever runs workloads written by someone else, narrow it with a NetworkPolicy instead.
- **ExternalDNS has nothing to do here.** It writes A records to UniFi only. The tunnel's record is
  a CNAME to a name Cloudflare owns, so nothing dynamic needs tracking.

## Related

- [architecture.md](architecture.md) — hostname tiers, certificate SANs, the LAN port posture
- [identity.md](identity.md) — the login surface: enumeration, lockout, MFA
- [observability.md](observability.md) — the alert rules that watch that login surface
- [secrets.md](secrets.md) — the OpenBao → ESO path the tunnel credential uses
