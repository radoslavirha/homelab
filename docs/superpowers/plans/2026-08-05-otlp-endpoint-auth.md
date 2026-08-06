# Securing the cross-cluster OTLP endpoint

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** proposal — pick ONE option below before implementing. Nothing here is started.

**Goal:** Decide what, if anything, should protect `otel.server3.home:4317`. Today it is unauthenticated plaintext gRPC reachable from anywhere on the LAN.

---

## The situation

server1 and server2 forward all telemetry to server3 over a single OTLP/gRPC destination. There is no authentication on that path.

The migration originally carried a shared bearer token from OpenBao. It was removed in `dd3dd49` for a hard technical reason, and that constraint shapes every option below:

```
grpc: the credentials require transport level security
      (use grpc.WithTransportCredentials() to set)
```

**gRPC refuses to attach per-RPC credentials to an insecure channel.** `tls.insecure: true` and `auth.type: bearerToken` cannot coexist — the exporter does not start at all. So:

> **Any option that keeps a bearer token on gRPC requires TLS. This is not negotiable.**

Separately, the token was never validated even when it was sent: `k8s-monitoring` exposes no server-side OTLP receiver auth. server3 accepted it without checking. So the endpoint has *always* relied on network isolation alone; removing the token changed the documentation, not the security posture.

### What is actually at risk

The endpoint is **write-only** — you cannot read telemetry back out of it. The realistic threat is *injection*: anything on 192.168.1.0/24 can push fabricated metrics, logs and traces into Prometheus, Loki and Tempo. Consequences are data pollution, misleading dashboards, and storage burn. Not data exfiltration.

Weigh the options against that, not against an internet-facing threat model.

### Relevant stack facts

| Fact | Implication |
|------|-------------|
| No cert-manager deployed anywhere | Any TLS option starts by adding it |
| Cilium is the CNI (13 CRDs present) | `CiliumNetworkPolicy` is available today, no new components |
| Traefik `otlp-grpc` entrypoint is raw TCP (`IngressRouteTCP`, `HostSNI(*)`) | TCP routes take no HTTP middleware — ForwardAuth cannot apply |
| An `HTTPRoute` already exists for `otel.server3.home` → 4318 | An OTLP/HTTP path exists if gRPC proves awkward |
| `otel-auth-token` ExternalSecret still syncs on server1/server2 (dormant) | A token-based option needs no new OpenBao work |

---

## Options

### Option A — Network policy only (recommended)

Restrict who may reach `alloy-receiver` using a `CiliumNetworkPolicy`, and leave the transport as it is.

**Why this first:** it addresses the actual threat (injection from arbitrary LAN hosts) with components already deployed, no certificates, no new failure modes, and nothing that can silently stop telemetry the way the bearer token did. For a private-network homelab this is proportionate.

- [ ] Add `gitops/k8s-manifests/server3/k8s-monitoring/CiliumNetworkPolicy.alloy-receiver.yaml` restricting ingress on 4317/4318 to the server1 and server2 node IPs (192.168.1.200, 192.168.1.201) plus in-cluster pods
- [ ] Verify Traefik's own source IP is allowed — traffic arrives via the IngressRouteTCP, so the policy must permit the Traefik pod, not the original client
- [ ] Confirm telemetry still arrives from both IoT clusters after applying
- [ ] Confirm a pod in an unrelated namespace is refused

> The Traefik hop is the catch: after TCP proxying, the source IP alloy-receiver sees is Traefik's, not server1's. A policy written against node IPs may therefore be a no-op. Verify before trusting it — and if so, the policy belongs on the Traefik entrypoint instead.

### Option B — mTLS via cert-manager

Client certificates replace the token. Identity is the certificate; nothing needs a shared secret.

- [ ] Deploy cert-manager (new ArgoCD app + AppSet, all clusters)
- [ ] Create a self-signed `ClusterIssuer` and an internal CA on server3
- [ ] Issue a server cert for `otel.server3.home`; terminate TLS at Traefik with `tls.passthrough` or at the receiver
- [ ] Issue client certs for server1/server2, delivered as secrets
- [ ] Set the otlp destination's `tls.cert`/`tls.key`/`tls.ca` and `insecure: false`
- [ ] Distribute the CA bundle to both IoT clusters
- [ ] Delete the dormant `otel-auth-token` ExternalSecrets

**Cost:** a new platform component, a CA to rotate, and cert expiry as a new way for telemetry to stop. **Benefit:** real mutual authentication, and the only option that authenticates the *client* rather than a shared secret.

### Option C — TLS + bearer token

Restores the original design by adding the transport security gRPC demands.

- [ ] Deploy cert-manager and a `ClusterIssuer` (as in Option B)
- [ ] Issue a server cert for `otel.server3.home`, terminate TLS at Traefik
- [ ] Restore on server1/server2: `tls.insecure: false` + `tls.ca`, `auth.type: bearerToken`, `bearerTokenFrom: env("OTEL_AUTH_TOKEN")`, and `collectorCommon.alloy.envFrom` injecting `otel-auth-token`
- [ ] **Solve server-side validation** — this is the open problem, see below
- [ ] Verify telemetry arrives from both IoT clusters

> **The token is still not validated.** k8s-monitoring has no server-side OTLP auth, so this option encrypts the transport and sends a credential nobody checks. Without a validating proxy in front of `alloy-receiver` it is strictly worse than Option B: same cert-manager cost, weaker guarantee. Only pursue it alongside Option D.

### Option D — Switch to OTLP/HTTP + Traefik ForwardAuth

The only route to a token that is actually *checked*.

- [ ] Repoint both IoT clusters' destination to `http://otel.server3.home:4318` with `protocol: http`
- [ ] Deploy a small ForwardAuth service that validates the bearer header against the OpenBao-sourced token
- [ ] Add a Traefik `Middleware` (ForwardAuth) and attach it to the existing HTTPRoute
- [ ] Retire the `otlp-grpc` entrypoint and the IngressRouteTCP
- [ ] Verify telemetry arrives and that a bad token is rejected

**Why HTTP:** ForwardAuth is HTTP middleware. The current gRPC path is an `IngressRouteTCP` with `HostSNI(*)`, and TCP routers take no middleware — so ForwardAuth is impossible without moving to 4318. Note that without TLS the token still crosses the LAN in cleartext; HTTP merely permits what gRPC refuses. Combine with Option C for a defensible result.

---

## Recommendation

**Do Option A.** It is the only option whose cost is proportionate to a LAN-only, write-only endpoint, and it uses Cilium which is already deployed.

Revisit B if the network stops being trusted — untrusted guests on the same VLAN, or clusters moving off-LAN. Prefer **B over C**: identical cert-manager cost, and B actually authenticates the client instead of shipping a credential nothing verifies.

**Do not implement C alone.** It reproduces the illusion of security that this plan exists to correct.

---

## Verify any option end to end

Sync status is not evidence. The bearer-token regression sat green in ArgoCD with Running pods and correct config on disk while two of three clusters sent nothing for half an hour.

- [ ] `count by (cluster) (kube_pod_status_phase)` returns **all three** clusters
- [ ] Loki `cluster` label values return **all three**
- [ ] `kubectl logs ds/k8s-monitoring-alloy-receiver -c alloy` on server1 shows no `failed to start scheduled component` and no repeating `Sender failed`
- [ ] Restart an Alloy pod and confirm it recovers — a config change alone does not restart a component that failed at startup

---

## Related

- `docs/observability.md` → "server1/server2 forwarding" documents the current unauthenticated state and the gRPC constraint
- `docs/secrets.md` → `otel-gateway/auth-token` describes the dormant credential
- `dd3dd49` removed the bearer token; `6bd36d9` fixed the unrelated node-exporter scrape gap
