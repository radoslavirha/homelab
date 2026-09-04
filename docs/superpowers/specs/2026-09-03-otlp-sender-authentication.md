# OTLP gRPC — authenticating senders

**Status:** open, and an **extension rather than unfinished work**. The TLS migration met its
goal: `.home` is retired, every HTTP path is HTTPS with a publicly-trusted certificate, and the
cross-cluster OTLP hop was encrypted on 2026-09-03. Nothing here is required for the homelab to
work correctly or securely against its current threat model.

**The gap:** the OTLP receiver is encrypted but does not know who is talking to it.

**Parent:** [`../plans/2026-09-03-tls-remaining-work.md`](../plans/2026-09-03-tls-remaining-work.md).
**Related:** [`../plans/2026-08-25-network-default-deny.md`](../plans/2026-08-25-network-default-deny.md) —
the same question asked at the network layer.

---

## What is true today

```
Alloy (server1, server2)  ──TLS──▶  Traefik (server3) :4317  ──h2c──▶  alloy-receiver
```

- Traefik terminates TLS against `server3-tls`, matching `HostSNI(otel.server3.homelab.irha.cz)`,
  and forwards plaintext h2c inside the cluster. ALPN negotiates `h2`, which is what makes gRPC
  work through a TCP terminator at all.
- Both senders verify the public chain (`tls.insecure: false`).
- Plaintext on 4317 no longer connects.

So the hop is **confidential** and the **receiver is authenticated to the sender**. The reverse
direction is unauthenticated: any host that can reach `192.168.1.202:4317` can complete a valid
TLS handshake and write telemetry.

## Why the existing certificates do not solve this

The most common wrong turn, so it is worth stating plainly.

A server certificate proves the **server's** identity to the client. It is presented to every
client that connects and contains no secret — it cannot also prove anything about the client.
Authenticating the client is a separate exchange, in the other direction, with a separate
keypair. That is all mTLS is: the same handshake run both ways.

Two specific reasons the certificates already in the cluster cannot be reused as client
credentials:

1. **They assert the wrong identity.** `server1-tls` is a server credential for names like
   `api.server1.homelab.irha.cz`. Presenting it as a client certificate asserts "I am a server
   called server1.homelab.irha.cz", which is not a claim Traefik can check against a list of
   permitted senders in any meaningful way.
2. **Extended Key Usage probably forbids it.** Public-CA certificates are constrained by EKU;
   Let's Encrypt's current profile is `serverAuth`. A validator enforcing EKU rejects such a
   certificate for client authentication outright.

> **Unverified, check before designing around it.** The EKU on the live certificate was not
> inspected — the attempt was made off-LAN. Confirm with:
> ```bash
> kubectl --context admin@server1 -n traefik get secret server1-tls \
>   -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -A1 "Extended Key Usage"
> ```
> If `TLS Web Client Authentication` is present, reason 1 still stands on its own.

## The actual risk

Not a sophisticated impersonator. The realistic case is a **misconfigured or compromised device
spraying junk into the observability stack** — poisoned dashboards, false alerts, wasted storage,
and a debugging session that starts from bad data. Injection, not disclosure: reading is already
prevented by TLS.

Weigh that against a LAN whose untrusted population is ESP devices, on a CGNAT connection with no
port forwards and no inbound path from the internet.

---

## Option A — `ipAllowList` TCP middleware (recommended)

Traefik supports an `ipAllowList` middleware for **TCP** routers. Applied to the `otel-grpc`
route, restricted to the two sending nodes:

```yaml
# sketch — confirm the TCP middleware field names against the running Traefik version
apiVersion: traefik.io/v1alpha1
kind: MiddlewareTCP
metadata:
  name: otlp-senders-only
  namespace: monitoring
spec:
  ipAllowList:
    sourceRange:
      - 192.168.1.200/32   # server1
      - 192.168.1.201/32   # server2
```

referenced from the route's `middlewares:`.

**Why this is likely the right answer:** it narrows "anything on the LAN" to "the two nodes that
are supposed to send", with no CA, no client keypairs, no distribution and no renewal. Ten lines,
and nothing new can rot.

It authenticates an **address**, not an identity — spoofable in principle, but not by an ESP
device on a switched LAN without something else already being very wrong.

**Check before implementing:**
- `ipAllowList` exists for both HTTP and TCP middlewares and **the field shapes differ**. Use the
  TCP one (`MiddlewareTCP`), and verify against the Traefik version in `helm-values/traefik.yaml`.
- Traefik runs `hostNetwork: true`, so it sees the real client address and no PROXY protocol or
  `forwardedHeaders` handling is needed. Confirm rather than assume — if the source address ever
  arrives translated, the allow-list silently blocks everything.
- Failure mode is loud and immediate: telemetry from a blocked sender stops. Verify with
  `count by (cluster) (up)` from all three clusters after applying.

## Option B — mTLS

Real client identity. Traefik does support it; the cost is entirely in the certificate
lifecycle.

```yaml
# TLSOption referenced from the otel-grpc route
spec:
  clientAuth:
    secretName: otlp-client-ca        # the CA cert clients must be signed by
    clientAuthType: RequireAndVerifyClientCert
```

The k8s-monitoring destination accepts `tls.cert` / `tls.key` (verified in
`_destination_otlp.tpl`, chart 4.3.2), so the sending side is configurable.

**The blocker is where the client certificate is issued:**

| Approach | Problem |
|---|---|
| Issue on each sending cluster | Needs the CA **private key** on server1 and server2. Copying a CA key to three clusters is a worse exposure than the one being closed. |
| Issue centrally on server3, deliver via OpenBao + ESO | Correct, but **nothing carries the renewal**. cert-manager renews the Secret on server3; pushing new material into OpenBao needs a Job or controller that does not exist. Renewal becomes a recurring manual step — the exact failure mode the certificate alerting exists to prevent. |
| Long-lived client certs (10 years) | Sidesteps renewal; a leaked certificate is then valid for a decade with no revocation path here. |

Server-side renewal is *not* a concern — cert-manager already renews `server3-tls` unattended.
Only the client half is unautomated.

**Rough cost:** a cert-manager self-signed Issuer → CA Certificate → CA Issuer on server3, a
`TLSOption`, two client Certificates, an OpenBao path and two ExternalSecrets, plus either a
small controller or an accepted manual step every renewal period.

## Option C — accept it

Defensible today, and should be written down as a decision rather than left as a silence. TLS
already prevents eavesdropping and receiver impersonation; the residual risk is injection from a
device already on a trusted LAN.

---

## Suggested order

1. Do **Option A**. It removes most of the exposure for almost no ongoing cost.
2. Leave **Option B** until a trigger makes it worth the lifecycle work:
   - an untrusted or unauditable device joins the LAN
   - a guest or IoT VLAN with routing to the cluster subnet
   - any exposure of this endpoint beyond the LAN
   - a second homelab site sending telemetry over a link you do not control
3. Revisit whichever is chosen when Authentik lands — if a service-identity story arrives with it,
   the answer for machine-to-machine auth may change shape entirely, and this endpoint should
   follow that rather than grow its own parallel scheme.

## Not in scope

- **MQTT** stays on both 1883 and 8883; that is a decided end state, not a transition. See the
  parent plan.
- **The 80 → 443 redirect** is dropped, not deferred.
- Application-level OTLP auth (bearer tokens) does not work here: `alloy-receiver` validates
  nothing, because k8s-monitoring exposes no server-side OTLP auth. A token would authenticate
  nothing while appearing to. The `otel-auth-token` ExternalSecret stays in place in case a
  future receiver validates it.
