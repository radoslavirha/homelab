# Network egress — what app pods are allowed to reach

`production` and `sandbox` on **server1 and server2** run under a default-deny NetworkPolicy.
An app pod can only reach what is explicitly allowed below. Everything else is dropped
silently — there is no error, no refusal, no log line. The call just hangs until the client's
own timeout fires.

**If you are here because something "works locally but times out in the cluster", read the
next section. That is the symptom this page exists for.**

## The one that catches people: ports 80 and 443 only

App pods may reach **any** internet host, but **only on TCP 80 and 443**.

Adding an external API to an app is a change in `iot-miniservers` (`externalApis` config).
Nothing there mentions network policy. So an HTTPS API works the moment you add it, and an API
on any other port — 8080, 8443, 9000, a database, an SMTP relay — fails with a timeout that
points at your HTTP client rather than at a firewall.

| You are calling | Works? |
| --- | --- |
| `https://api.example.com` (443) | yes |
| `http://api.example.com` (80) | yes |
| `https://api.example.com:8443` | **no — dropped** |
| anything on the LAN (`192.168.x.x`) | **no** unless it is the miIO device rule below |
| another pod or namespace | **no** unless listed in the table below |

To allow a new port, see [Changing what is allowed](#changing-what-is-allowed).

## Confirming it is the policy, in one command

Run this while reproducing the failing call. If the policy is the cause, the dropped packet
appears here; if nothing appears, the problem is elsewhere and this page is a dead end.

```bash
kubectl --context admin@server1 -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace production --type drop --follow
```

A policy drop looks like this — note `DROPPED` and `Policy denied`:

```text
production/api-iot-my-api-xxxx:41234 -> 203.0.113.10:8443 (world) Policy denied DROPPED (TCP Flags: SYN)
```

Swap `admin@server1` for `admin@server2` and `production` for `sandbox` as needed. Both
clusters and both namespaces carry an identical policy set.

## What is allowed today

Source of truth: `gitops/k8s-manifests/<cluster>/network-policies/<namespace>/`. The two
clusters' directories are byte-identical and must stay that way — `diff -r` between them is
empty.

### Every pod in the namespace

| To | Port | File |
| --- | --- | --- |
| CoreDNS (`kube-system`) | UDP+TCP 53 | `NetworkPolicy.dns-egress.yaml` |
| the internet, excluding RFC1918 | TCP 80, 443 | `NetworkPolicy.egress-internet.yaml` |
| the Kubernetes apiserver | TCP 443, 6443 | `CiliumNetworkPolicy.egress-apiserver.yaml` |

Reaching the apiserver is not the same as being able to use it: the app
ServiceAccounts set `automountServiceAccountToken: false`, so pods hold no cluster credentials
and an unauthenticated request returns `401`. That setting also removes `ca.crt` — to verify the
apiserver's TLS, mount the **`kube-root-ca.crt`** ConfigMap, which Kubernetes publishes into
every namespace. Verified working in all four namespaces; a `curl --cacert /ca/ca.crt` against
`https://kubernetes.default.svc/openid/v1/jwks` completes the handshake and returns `401`.

### Per app

| App | To | Port | File |
| --- | --- | --- | --- |
| `miot-bridge-api` | MongoDB | TCP 27017 | `NetworkPolicy.egress-miot-bridge-api.yaml` |
| `miot-bridge-api` | EMQX (MQTT) | TCP 1883 | same |
| `miot-bridge-api` | Alloy (OTLP) | TCP 4318 | same |
| `miot-bridge-api` | `192.168.1.0/24` — miIO devices | **UDP 54321** | `NetworkPolicy.egress-lan-miio.yaml` |
| `qr-manager-api` | MongoDB | TCP 27017 | `NetworkPolicy.egress-qr-manager-api.yaml` |
| `qr-manager-api` | Alloy (OTLP) | TCP 4318 | same |
| `interactive-map-feeder-api` | Alloy (OTLP) | TCP 4318 | `NetworkPolicy.egress-interactive-map-feeder-api.yaml` |
| `qr-manager-ui` | *(nothing)* | — | static SPA; DNS and internet only, from the namespace-wide rules |

### Ingress

Only the node reaches app pods — kubelet health probes and Traefik, which runs `hostNetwork`,
so both arrive with the same identity. **TCP 4000** (the APIs) and **TCP 80** (`qr-manager-ui`)
only, via `CiliumNetworkPolicy.host-ingress.yaml`.

There is no pod-to-pod ingress and no metrics scraping — the apps push OTLP rather than being
scraped. **A new inbound port needs a policy change**, including any UDP listener: the
miot-bridge UDP listener on 4000 was removed in part because the policy permits TCP only.

## Changing what is allowed

Use the **`network-egress`** skill (`.apm/skills/network-egress/`) — it carries the procedure
and, importantly, the verification step. Rough shape:

1. Edit the right file under `gitops/k8s-manifests/server1/network-policies/<ns>/` **and** copy
   it to `server2/`. Keep the two identical.
2. Update the table on this page in the same commit.
3. Sync `network-policies-<cluster>-<ns>` in ArgoCD — these Applications are **manual-sync** on
   purpose.
4. **Restart a pod and watch it come up clean.** Cilium tracks connections in conntrack, so
   established connections survive a policy change: a broken policy looks fine at apply time
   and breaks at the next reconnect or rollout, decoupled from the change that caused it.

## If you have broken something

Removing a policy takes effect immediately, with no pod restart:

```bash
kubectl --context admin@server1 -n production delete networkpolicy default-deny
```

That restores ingress. To fully un-restrict a namespace, delete `allow-dns-egress` too — it is
the file that actually arms egress enforcement, because `podSelector: {}` selects every pod and
a pod selected by any egress policy denies everything it does not match.

The ArgoCD Applications are manual-sync precisely so `selfHeal` cannot undo this rollback.

## Background

Survey, evidence and rollout record:
[`docs/superpowers/plans/2026-08-25-network-default-deny.md`](superpowers/plans/2026-08-25-network-default-deny.md).
