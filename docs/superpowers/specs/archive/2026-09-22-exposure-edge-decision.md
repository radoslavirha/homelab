# How the house is reached from outside — the edge decision

**Status:** **DECIDED, EXECUTED and archived 2026-09-22.** Cloudflare Tunnel, one per cluster.
Kept as the record of what was rejected and why, so it is not relitigated: port-forwarding (no
inbound path under carrier NAT, and three clusters against one WAN port), a household VPN
(WireGuard, Teleport, Tailscale — all fail the requirement that any device works with nothing
installed and nothing remembered), Tailscale Funnel (public HTTPS without the edge seeing
plaintext, but `*.ts.net` names only, which breaks the one-hostname rule), and a rented VPS (the
only option with no third party in the plaintext path, at the cost of a second internet-facing
machine).

**The working reference is [`docs/public-exposure.md`](../../public-exposure.md).**

**The question, stated once:** who needs to reach these services, and can they be asked to install
something first? Everything below follows from that, and it is not a technical question.

---

## The framing that decides it

There are two populations, and they need different things.

| Population | Example | Can install a client? |
| --- | --- | --- |
| **You and the household** | your phone, your laptop, your partner's phone | yes — a one-time profile install |
| **Anyone else** | someone scanning a QR code on a jar in the kitchen | **no** |

A VPN serves the first population completely and the second not at all. A public edge serves both
and costs a permanently exposed login page. **The mistake to avoid is paying the second cost for
names only the first population ever uses.**

### What each name actually needs

| Name | Who reaches it | Needs no-install access? |
| --- | --- | --- |
| `qr.irha.cz` | **anyone** who scans a printed QR code | **Yes — hard requirement.** A stranger with a phone camera cannot join a VPN |
| `mealie.irha.cz` | household; occasionally a shared recipe link | Only if recipes get shared outside the house |
| `assistant.irha.cz` | household | No |
| `grafana.irha.cz` | you, alone | No |
| `auth.irha.cz` | whoever uses the four above | **Only because something above it is public** |

**`qr.` is the only name with an unavoidable public requirement**, and it is the one that needs no
login at all — it is a redirect service behind an `addPrefix /r` middleware, reaching no API.

That asymmetry is the whole finding. Verify the middle two rows against how the household actually
behaves before choosing; they are the rows that move the answer.

---

## Threat model

Worth writing down, because the options differ only under one of these.

| Adversary | Reality | Which options survive |
| --- | --- | --- |
| **Opportunistic scanners** — the internet-wide background noise | Constant, automated, uninterested in you. Hits any open port within hours | All. A public Authentik with MFA and a lockout policy handles this; a VPN is simply invisible to it |
| **Credential stuffing** with passwords leaked elsewhere | Plausible. Reused passwords are the normal way a homelab falls | All, roughly equally — MFA is the control, and it is already enforced |
| **A targeted adversary** who wants *your* data | Unlikely for a household homelab, and the only case where "who terminates TLS" matters | VPN and self-hosted edges. Cloudflare Tunnel does not |
| **You, at 2am, locking yourself out** | The most probable incident on this list by a wide margin | The option with the fewest moving parts wins, and that is not the one with the most features |

**Honest reading:** for a household homelab the realistic adversary is noise and reused passwords,
not a targeted attacker. That argues the TLS-termination question matters less than the
operational-surface question — how much is exposed, and how many components must stay patched.

---

## The options

### A — Cloudflare Tunnel (`cloudflared`)

Outbound-dialled tunnel; hostnames map to Traefik in the tunnel's own ingress rules.

- **Cost:** free.
- Allow-list is structural; one tunnel per cluster solves the three-cluster problem; no port
  forward, no published home address.
- **Cloudflare terminates TLS and sees plaintext**, including every password posted to
  `auth.irha.cz`.
- Adds a component to run, upgrade and debug, plus the work in the exposure spec's steps 1–2
  (`forwardedHeaders.trustedIPs`, Authentik's proxy trust, the `ipAllowList` review).

### B — Port-forward 443 to a second Gateway listener

- **Cost:** free. Now buildable — the WAN address is public again.
- Nobody but you sees decrypted traffic; no new component.
- Publishes the home address; the allow-list becomes a convention someone must remember on every
  HTTPRoute; **no clean answer for three clusters** — one WAN `:443`, three Traefiks.

### C — UniFi's built-in VPN, two flavours

**Hardware confirmed 2026-09-22: UniFi Express 7 (UX7), latest firmware.** It supports Identity
Endpoint, **Teleport**, **WireGuard**, OpenVPN and L2TP as VPN servers, so both flavours below are
available with no new hardware.

**C1 — WireGuard server.** Peers configured by hand in the console, standard WireGuard clients.
**C2 — Teleport.** Ubiquiti's zero-config VPN, WireGuard underneath. You generate an invitation
in the console, send the link, the recipient opens it in the **WiFiman** app and taps once. No
config file, no port forward, **and it works when either end is behind NAT**. Invitations expire
after 24 hours and each is good for one device; some setups need IPv6 on the WAN.

**Which for whom:** Teleport for phones and anyone non-technical; WireGuard for laptops, for
always-on, and for anything you want under your own control. They coexist — this is not a choice
of one.

- **Cost: free**, built into UniFi OS — no extra hardware, no subscription, no third party.
- **Attack surface is one UDP port that does not answer unauthenticated packets at all** — a
  scanner cannot tell it is there. Compare with a public login page, which by design answers
  everyone.
- **Nothing in this repo changes.** No `trustedIPs`, no proxy trust, no Authentik change, no
  second entrypoint, no new component in the clusters. Split horizon keeps working: the VPN client
  uses UniFi for DNS and gets `192.168.1.20x`, exactly as on the LAN. Steps 1 and 2 of the
  exposure spec disappear entirely.
- **Cost that is not money:** every person needs an app installed once, guests cannot be handed a
  link that just works, and `qr.` cannot work this way at all.

#### "Does it have to run permanently?" — no

This is the objection that usually kills VPN-for-the-household, and it rests on a false premise.

| | What it means |
| --- | --- |
| **Split tunnel** | Set the peer's `AllowedIPs` to `192.168.1.0/24` only. Just homelab traffic enters the tunnel; Netflix, banking and everything else go straight out. No privacy change, no throughput cost, negligible battery |
| **At home: off** | On the house wifi there is no tunnel at all — split horizon already answers `192.168.1.20x` |
| **iOS on-demand** | The WireGuard app can bring the tunnel up automatically on any network that is not the home SSID, and drop it on arrival. Nobody taps anything |
| **Teleport** | On-demand by nature — open WiFiman, tap, done |

**The honest residue:** on-demand WireGuard is genuinely invisible once installed, but it is a
profile on someone else's phone that you will occasionally have to support. Teleport is easier to
install and *less* invisible — somebody must remember to tap. **If a household member opening
Mealie in a supermarket must first remember a VPN, that is the cost, and it is a real one.** It is
also the exact moment to publish `mealie.` instead.

### D — Tailscale (mesh, not Funnel)

- **Cost: free** on the Personal plan — 6 users, unlimited user devices, 50 tagged resources.
- Nicer than raw WireGuard: MagicDNS, no port forward, works even if the ISP re-CGNATs, easy
  per-device revocation, good iOS/macOS clients.
- **A third party holds the coordination plane** (not the traffic — data is WireGuard
  point-to-point). Self-hosting that plane is possible with Headscale, at the price of running it.
- Same population limit as C: no-install access is impossible.

### E — Tailscale Funnel — **rejected, and worth recording why**

Funnel looks like the perfect answer: public HTTPS, and **Tailscale does not terminate TLS** — it
routes on the SNI name and proxies the encrypted TCP connection to your node, so the edge sees no
plaintext. That is strictly better than Cloudflare on the one axis where Cloudflare loses.

**It cannot serve `auth.irha.cz`.** Funnel serves only `*.ts.net` names; the certificate is valid
for that name alone, so a CNAME from a custom domain fails the handshake. Using it would mean a
second hostname per service — which breaks the `iss` claim, splits the browser origin, and is the
one invariant the exposure spec says never to break. Rejected on that, not on quality.

### F — Your own VPS as the edge

A cheap VPS runs Traefik or Pangolin, joined to the house by WireGuard; TLS terminates on a
machine **you** control.

- **Cost: a monthly rental**, the only option here that is not free.
- Keeps third parties out of the plaintext path while still giving no-install public access.
- **Adds a second machine to patch, monitor and back up** — an entire second operational surface,
  and one that is itself internet-facing.

### G — Hybrid: VPN for the household, public edge for `qr.` only

C or D for everything the household reaches, plus the smallest possible public edge for the one
name that genuinely needs strangers.

- `qr.` has no login, no API, no user data — a redirect service. Publishing it exposes almost
  nothing, and it is the only name whose public exposure buys something a VPN cannot.
- `auth.irha.cz` stays **private**, which removes the single largest argument in this whole
  analysis: nobody is spraying a login page that is not reachable.
- **Cost:** two mechanisms instead of one, and a decision to revisit the moment someone wants to
  share a Mealie link.

---

## Cost summary

| | Money | New components | Third party sees plaintext | Serves strangers | Work in this repo |
| --- | --- | --- | --- | --- | --- |
| A Cloudflare Tunnel | free | `cloudflared` ×N | **yes** | yes | steps 1–2, plus per-name |
| B Port-forward | free | none | no | yes | step 1 partially, one cluster only |
| C UniFi WireGuard | free | none | no | **no** | **none** |
| D Tailscale | free (6 users) | client per device | no | **no** | none |
| E Funnel | free | — | no | yes, wrong hostname | **rejected** |
| F Own VPS | ~a monthly rental | a whole VPS | no | yes | steps 1–2 + VPS ops |
| G Hybrid (C or D + `qr.`) | free | one small tunnel | only for `qr.` | yes, for `qr.` | step 2 for one name |

---

## Decision (2026-09-22)

**Tailscale (option D) for household access.** Not the UX7's WireGuard server — that requires an
inbound UDP port, and CGNAT means no port of yours is reachable from the internet, at any price
short of a monthly add-on for a public IPv4 (declined).

**What CGNAT eliminates outright:**

| Dead | Why |
| --- | --- |
| UniFi WireGuard server | needs an inbound listener |
| Port-forward (option B) | nothing to forward to |
| `vpn.irha.cz` + DDNS | no address of yours is routable, so the record would point at nothing usable |
| IPv6 as a workaround | measured 2026-09-22: no IPv6 at all on this line — ULA only, `ping6` to `2606:4700:4700::1111` is "No route to host" |

**What survives — only outbound-dialled paths:**

| Option | Household access | Cost | Note |
| --- | --- | --- | --- |
| **Tailscale** | **yes, and can stay always-on on iOS** | free, 6 users | WireGuard underneath, DERP relays traverse CGNAT, MagicDNS. Third party holds the coordination plane |
| Teleport | yes, but **manual tap every time** | free | Already on the UX7. Fails the "must work always" requirement for phones |
| Cloudflare Tunnel | no — it publishes services, not a VPN | free | Still the answer for any name strangers must reach |

**Tailscale wins on the one hard requirement:** the phones must work without anyone thinking about
it, and Tailscale can run always-on. Teleport cannot. Both are free; both traverse CGNAT.

**Keep Teleport enabled as the spare key.** Zero cost, different failure mode, no dependency on
Tailscale's control plane.

### Design problems (solve before rollout)

**1. No endpoint record is needed at all.** Tailscale devices find each other through its
coordination plane; nothing dials an address of yours. So the plan to add `vpn.irha.cz` to
Cloudflare is **dropped** — the public zone stays empty, which is the state this repo has
deliberately maintained since 2026-09-02.

**2. DNS still needs a decision.** Tailscale's MagicDNS handles its own names, not
`grafana.irha.cz`. Either push UniFi (`192.168.1.1`) as the tailnet's DNS — with the same
failure mode as before, phones resolving nothing when the house internet is down — or publish
`A` records for the apex names pointing at `192.168.1.20x`, which resolve identically everywhere
and make nothing reachable on their own. The second remains the recommendation.

**3. Subnet routing must be enabled deliberately.** A plain Tailscale install reaches only other
Tailscale devices. To reach `192.168.1.200-202` — which is the entire point — one node on the
LAN must advertise `192.168.1.0/24` as a subnet route, and that route must be approved in the
admin console. That node becomes a dependency: if it is down, the household has no access.
Choose it deliberately (the UX7 itself cannot run Tailscale; a cluster node or a small always-on
box can).

**4. The coordination plane is a third party.** Traffic is WireGuard point-to-point and Tailscale
cannot read it, but they decide who may join the tailnet. Self-hosting that plane is possible
(Headscale) at the cost of running it. Accepted for now; noted so it is a choice.

### Still to decide: `qr.irha.cz`

A printed QR code is scanned by whoever picks up the jar. If that is ever someone outside the
household, `qr.` must be publicly reachable and no VPN can serve it. It is also the safest thing
here to publish: a redirect service behind an `addPrefix /r` middleware, no login, no API, no user
data. **If the codes are only ever scanned by people in the house, publish nothing at all.**

## On Teleport — rejected for phones, and why the obvious advice is wrong

Ubiquiti's own guidance, and most write-ups, say *Teleport for phones, WireGuard for laptops*.
That is backwards for this requirement. **Teleport has no on-demand activation** — somebody opens
WiFiman and taps, every time. WireGuard on iOS connects by itself. So WireGuard is the phone
option here, and Teleport is the convenience option for a guest laptop.

(Teleport invitations expire after 24 hours and cover one device — but that is the *invitation*,
not the connection; the profile persists once installed. It is the tap that disqualifies it, not
the expiry.)

## Option G, adopted rather than rejected

The per-name table is what makes this work: four of the five names are reached only by people who
can install a profile once, and the fifth (`qr.`) is the one carrying no login and no data. That
is why the household goes on the VPN and at most one name goes public — see
[Still to decide](#still-to-decide-qrirhacz).

Move to **D** (Tailscale) only if managing peers by hand becomes tiresome, or if the ISP
re-CGNATs the house — Tailscale survives that and a UDP listener does not.

## Open questions — answer these before rollout

- [x] ~~Which UniFi gateway?~~ **UniFi Express 7, latest firmware** — supports WireGuard, Teleport,
      OpenVPN, L2TP and Identity Endpoint. Answered 2026-09-22.
- [ ] **Do strangers ever scan the QR codes?** If yes, `qr.irha.cz` is published and the rest stays
      private. If no, nothing is published at all. This is the only remaining exposure decision.
- [ ] **Which DNS approach** — `DNS = 192.168.1.1` in the profile, or public `A` records pointing
      at the LAN addresses. See [Design problems](#design-problems-solve-before-rollout). Test the
      chosen one with the house internet unplugged.
- [ ] **The endpoint name.** One public `A` record (`vpn.irha.cz`) tracking the WAN address, and
      what keeps it current now that the UniFi DDNS client is gone — re-enable it for that single
      name, or accept manual updates.
- [ ] **How many peers, and who manages them?** Every WireGuard peer is configured by hand on the
      UX7. Fine for a household; worth knowing the number before starting.
- [ ] **Does anything need access from a device that cannot install a profile?** A guest's laptop,
      a work phone with MDM restrictions. That is the failure mode of this whole design, and it is
      a household question, not a technical one.

## Out of scope

- The mechanics of whichever edge wins — that is [`2026-09-01-public-exposure.md`](2026-09-01-public-exposure.md).
- Cloudflare Access, SMTP, and publishing any API hostname. All gated elsewhere.
