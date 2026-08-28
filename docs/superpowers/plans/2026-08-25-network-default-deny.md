# Default-deny network policy — Stage 1 survey and draft allowlist

**Scope:** this repository only. Phase 0.2 — the survey, the allowlist it produced, and the
enforced rollout on server2. **server2 is enforced and verified as of 2026-08-26** (see
[Stage 3 — enforced on server2](#stage-3--enforced-on-server2-2026-08-26)). server1 is not.

**Task definition:** [`iot-miniservers` → `docs/superpowers/specs/2026-08-25-auth-phase-0-hardening.md`](../../../../iot-miniservers/docs/superpowers/specs/2026-08-25-auth-phase-0-hardening.md),
section **0.2 — Default-deny network policy**. That document is the authority; this one is the durable
artifact it asks for ("Record the inventory in the homelab repo. It is the durable artifact of this
task — more valuable long-term than the policies themselves").

**Policies:** [`gitops/k8s-manifests/server2/network-policies/`](../../../gitops/k8s-manifests/server2/network-policies/) — `production/` and `sandbox/`
**ArgoCD:** [`apps/network-policies/NetworkPolicies.yaml`](../../../gitops/argocd-manifests/apps/network-policies/NetworkPolicies.yaml) (ApplicationSet, one Application per namespace, **manual sync**) under [`roots/RootNetworkPolicies.yaml`](../../../gitops/argocd-manifests/roots/RootNetworkPolicies.yaml) at wave 5

## Status — 2026-08-26

| Stage | State |
| --- | --- |
| Stage 1 — survey | **done, with stated confidence limits.** Flow inventory below. Live observation window was ~18 minutes; the gaps are named explicitly rather than papered over. |
| Stage 2 — audit mode | **skipped, deliberately.** Audit mode forwards everything, so it cannot detect the connection-reuse failure this document warns about — the one where a bad policy looks fine until the next reconnect. A rolling restart under real enforcement tests exactly that, and sandbox gave a free canary with instant rollback. `PolicyAuditMode` remains `Disabled` on all three clusters. |
| Stage 3 — deny | **enforced and verified on both clusters.** server2 2026-08-26, server1 2026-08-28, sandbox before production each time. Zero drops in all four namespaces. Evidence below. |
| Apiserver egress | **fixed and verified, 2026-08-28.** Nine objects per namespace now. See [apiserver egress](#the-gap-this-rollout-left-apiserver-egress). |

---

## Read this first: what the survey can and cannot tell you

The brief's own warning is that surveying before denying is the entire safety property. The honest
finding from doing it is that **direct observation alone is not sufficient here, and a policy built
only from observed flows would cause an outage.** Three of the most important flows produce no traffic
at all under normal idle conditions:

- **DNS** — the app pods hold long-lived connections and resolved their names at startup. Over 18
  minutes, the four server2 app workloads emitted **zero** DNS queries. Deny DNS on the strength of
  that and everything breaks on the next pod restart.
- **CHMI internet egress** — `interactive-map-feeder-api` calls CHMI only while serving a user
  request, and its health check is deliberately passive (`UpstreamHealthCheck.ts`: *"No synthetic
  request is issued"*). An idle window shows nothing, forever.
- **miIO LAN egress on server2** — both server2 miot-bridge pods log `Loaded 0 subscription(s) across
  0 device(s)`. The poller runs every 5s against an empty device list. The flow appears the moment
  someone registers a device, which is exactly when nobody is watching a policy.

So this inventory is built from **three** evidence sources, and each row below says which one it rests
on:

| Evidence | What it is | Window |
| --- | --- | --- |
| **Hubble** | `hubble observe --follow` on the Cilium agent of each node | ~18 min live, both clusters |
| **App OTel metrics** | the applications' own `http_client_request_duration_seconds` / `miot_client_call_duration_seconds`, in Prometheus | **~30 days** |
| **Config** | rendered ConfigMap templates, helm values, source | current state |

The app-metrics source is what rescues this survey. It is a per-destination record of every outbound
HTTP call each app made, with a `server_address` label, retained ~30 days — which covers the
intermittent flows Hubble could never have caught in one session.

> **The Hubble ring buffer is not a retrospective tool here.** It holds ~4095 events per node and these
> nodes generate ~4000 flows/minute, so it turns over in **about 60 seconds**. `--last N` bought
> essentially no history. Only the `--follow` capture counted.

---

## The verified flow inventory

### production / sandbox — egress

| From | To | Port/proto | Why | Evidence |
| --- | --- | --- | --- | --- |
| every pod | `kube-system/coredns` | UDP+TCP 53 | name resolution | **Hubble (server1 only)**, 56 flows from `miot-bridge-api`. Zero on server2 — see caveat above. Also seen pre-DNAT as `10.96.0.10:53`. |
| `miot-bridge-api` | `mongodb/mongodb` | TCP 27017 | device + subscription state | Hubble, both clusters, both ns |
| `qr-manager-api` | `mongodb/mongodb` | TCP 27017 | QR records | Hubble, both clusters, both ns |
| `miot-bridge-api` | `iot/emqx` | TCP 1883 | MQTT publish/subscribe | Hubble, both clusters, both ns |
| all three APIs | `monitoring/k8s-monitoring-alloy-receiver` | TCP 4318 | OTLP traces + metrics | Hubble + app metrics, both clusters |
| `miot-bridge-api` | `192.168.1.85` (LAN) | **UDP 54321** | miIO device polling, every 5s | **Hubble, server1 production only** — 182 packets in the window |
| `miot-bridge-api` | `192.168.1.140` (LAN) | **UDP 50450** | Loxone HA controller notifications | **Config only** — `udp.notifications.address`. Change-driven, not observed. Enabled in **both** production and sandbox. |
| `interactive-map-feeder-api` | `intranet.chmi.cz` | TCP 443 | weather portal | **App metrics, server1 only** — samples on ~8 separate days, idle ~9 days |
| `interactive-map-feeder-api` | `opendata.chmi.cz` | TCP 443 | weather open data | **App metrics, server1 only** — same shape |
| `miot-bridge-api` | `miot-spec.org` | TCP 443 | device spec lookup | **Config only — no calls in the full ~30d retention.** Device-registration path. |
| `qr-manager-ui` | *(nothing)* | — | static nginx; no egress observed at all | Hubble |

### production / sandbox — ingress

| From | To | Port/proto | Why | Evidence |
| --- | --- | --- | --- | --- |
| **host** (`cilium_host`) | all three APIs | TCP 4000 | kubelet `/health/live`, `/health/ready` **and** all Traefik ingress | Hubble, both clusters — ~1000-1900 flows per workload |
| **host** (`cilium_host`) | `qr-manager-ui` | TCP 80 | same two callers | Hubble, both clusters |

**That is the complete ingress set.** Over the whole window, on both clusters, every packet arriving at
a production/sandbox pod on a service port came from the node's `cilium_host` address — `10.244.0.186`
on server2, `10.244.0.188` on server1. There is no pod-to-pod ingress and **no metrics scraping**: the
apps push OTLP rather than being scraped, so `monitoring` never initiates to them.

### Adjacent flows worth knowing (not in scope for these policies)

| From | To | Port/proto | Note |
| --- | --- | --- | --- |
| `monitoring/k8s-monitoring-alloy-receiver` | `192.168.1.202:4317` | TCP | **this** is the cross-cluster OTLP hop to `otel.server3.home` — not the app pods |
| `external-secrets/external-secrets` | `192.168.1.202:80` | TCP | `vault.server3.home`, plain HTTP. Confirmed via `ClusterSecretStore/openbao` |
| `external-dns/external-dns` | `192.168.1.1:443` | TCP | router API — not in the brief's expected list |

---

## Expected vs. found

The brief's table was explicitly a hypothesis. Scoring it:

### Confirmed as stated

- every pod → CoreDNS *(confirmed on server1; see the caveat — not observable on server2)*
- kubelet → pods for probes
- `qr-manager-api`, `miot-bridge-api` → MongoDB
- `miot-bridge-api` → EMQX
- `interactive-map-feeder-api` → `intranet.chmi.cz`, `opendata.chmi.cz` *(via app metrics, server1)*
- `miot-bridge-api` → Xiaomi devices on `192.168.1.0/24` over UDP *(server1)*
- `miot-bridge-api` → Loxone webhook *(config; UDP, not HTTP — see correction)*
- `external-secrets` → `vault.server3.home`
- Traefik → app pods *(configured and real; see correction on the mechanism)*

### Corrections — the brief is wrong on these

1. **App pods do not egress to `otel.server3.home`.** They send OTLP to
   `k8s-monitoring-alloy-receiver.monitoring.svc.cluster.local:4318`, in-cluster. The Alloy receiver
   forwards to `192.168.1.202:4317`. **The cross-cluster hop belongs to the `monitoring` namespace.**
   This is the brief's own "easiest to forget" item, and the good news is that default-deny on
   production/sandbox cannot break it. It also means no FQDN or LAN rule is needed for telemetry.

2. **"There are no NetworkPolicy or CiliumNetworkPolicy objects in the cluster today" is false.**
   `mongodb/mongodb` exists on **both** server1 and server2 (111d / 121d old, from the Bitnami chart),
   and `monitoring/grafana-image-renderer-ingress` exists on server3. The MongoDB one selects the
   MongoDB pods, permits ingress on 27017 **from any source**, and permits all egress — so it is
   already policy-selected but not meaningfully restrictive. Worth tightening once
   production/sandbox are its only legitimate clients, as a follow-up to this work.

3. **The Loxone destination is UDP, not an HTTP webhook.** `udp.notifications.address` is
   `192.168.1.140:50450`. The HTTP notification channel is present in config but
   `http.notifications.enabled: false` in both production and sandbox. A rule written for an HTTP
   webhook would be the wrong protocol and the wrong port.

4. **Traefik reaches the apps through Gateway API `HTTPRoute`s, not Ingress or IngressRoute.** There
   are no `Ingress` objects at all and the only `IngressRoute` is Traefik's own dashboard. Eight
   HTTPRoutes cover the two namespaces via the `traefik-gateway` Gateway on `192.168.1.201`.

5. **`server1` is not a quiet secondary.** The brief's 0.1 section calls it "largely idle". For 0.2
   that is actively misleading: server1 runs the same full app set in both namespaces **and is the
   only cluster where the miIO device path and the CHMI egress are live.** See below.

### Found, not on the list

- **`miot-bridge-api` exposes a UDP listener** on port 4000 with a ClusterIP Service
  (`api-iot-miot-bridge-api-udp`). It is **not** LAN-reachable — no `UDPRoute` exists, the Gateway
  listens on HTTP/80 only — so no inbound rule is needed today. If it is ever exposed, an ingress rule
  becomes necessary and the drafts here do not cover it.
- **`external-dns` → `192.168.1.1:443`** (router API).
- **A transient MQTT reconnect loop at startup.** On server2, production `miot-bridge-api` flapped
  connect/disconnect against EMQX roughly every 5s for the first minute after boot, then settled.
  Zero occurrences in the last 5 minutes of the window. Pre-existing, unrelated to this work, and not
  a policy concern — but it is the reason the EMQX flow count looks low.

---

## server1 is the cluster that matters

This is the single most consequential finding, and it changes where the risk sits.

| | server1 | server2 |
| --- | --- | --- |
| App set in `production` + `sandbox` | full | full |
| miot-bridge registered devices | **1** (`192.168.1.85`, 6 subscriptions) | **0** |
| miIO UDP polling | **live, every 5s** | none — nothing to poll |
| `miot_client_call_duration_seconds_count` | present (674 calls, `get_properties`) | **metric does not exist** |
| CHMI egress, ever, in 30d retention | **yes** | **never** |

The drafts live under `server2/` because the task placed them there. **server1 needs an identical set,
and server1 is where a mistake in the LAN egress rule actually breaks the house.** The two clusters'
policy sets should be kept identical rather than tailored to current behaviour — because current
behaviour changes the moment a device is registered on server2.

There is also a caveat about using sandbox as a canary: **sandbox is not isolated from the house.**
`sandbox/miot-bridge-api` has device polling enabled and points at the same real Loxone controller
(`192.168.1.140:50450`) as production. It is a fine canary for the in-cluster rules and a poor one for
the LAN rules.

---

## The policies

In [`gitops/k8s-manifests/server2/network-policies/`](../../../gitops/k8s-manifests/server2/network-policies/),
split `production/` and `sandbox/`, named `<Kind>.<qualifier>.yaml` to match the rest of
`k8s-manifests/` (`ExternalSecret.mqtt.yaml`, `HTTPRoute.yaml`, …).

**Merging them is inert.** No ArgoCD Application points at `gitops/k8s-manifests/**/network-policies/`.
Note the earlier claim that "every Application uses an explicit `path:`" was wrong in general — the
`Root*.yaml` app-of-apps *do* use `directory.recurse: true`, but over
`gitops/argocd-manifests/apps/<group>`, i.e. they pick up **Application definitions**, not manifests. So
the arming step is adding an Application under `gitops/argocd-manifests/apps/<group>/` pointing at this
path; `root-iot` then auto-creates it (`prune: true`, `selfHeal: true`) and the policies go live at once.
Do not put that Application in the same commit as the policies.

| File (per namespace) | Type | Covers |
| --- | --- | --- |
| `NetworkPolicy.dns-egress.yaml` | NetworkPolicy | DNS to CoreDNS, every pod |
| `CiliumNetworkPolicy.host-ingress.yaml` | **CiliumNetworkPolicy** | all ingress — probes and Traefik |
| `NetworkPolicy.egress-miot-bridge-api.yaml` | NetworkPolicy | MongoDB, EMQX, OTLP |
| `NetworkPolicy.egress-qr-manager-api.yaml` | NetworkPolicy | MongoDB, OTLP |
| `NetworkPolicy.egress-interactive-map-feeder-api.yaml` | NetworkPolicy | OTLP |
| `NetworkPolicy.egress-lan-miio.yaml` | NetworkPolicy | miIO UDP/54321 to the LAN `/24` |
| `NetworkPolicy.egress-internet.yaml` | NetworkPolicy | outbound 443/80, private ranges excluded |
| `NetworkPolicy.default-deny.yaml` | NetworkPolicy | ingress + egress deny for unselected pods |

Seven of the eight objects per namespace are plain `NetworkPolicy`, per the portability goal. One is not.

**`CiliumNetworkPolicy.host-ingress.yaml` uses `fromEntities: [host]`, and it is not optional.** A plain
NetworkPolicy could only say "allow the node" as an `ipBlock`. On this cluster that silently fails:
Cilium's CIDR selectors do not match the `host`/`remote-node` identities unless `policyCIDRMatchMode`
includes `nodes`, and it is unset here — verified, `PolicyCIDRMatchMode: []`. An `ipBlock` rule would
look correct, pass review, match nothing, and take down every health probe **and** all user-facing
ingress simultaneously. This is the single most likely way to turn this task into an outage.

(Cilium separately auto-allows host→pod ingress by default, `allow-localhost=auto`, so probes would
probably survive with no rule at all. That is a default, not a contract, and is deliberately not
relied on.)

### Changes since the first revision (2026-08-26)

- **`toFQDNs` internet rules removed.** Replaced by `NetworkPolicy.egress-internet.yaml`. Rationale in
  [Maintaining these policies](#maintaining-these-policies--read-before-adding-anything-to-an-app). This
  also removes the Cilium DNS proxy from the path, and with it the `rules.dns` blocks the FQDN rules
  needed.
- **Loxone UDP/50450 egress rule removed.** Loxone consumes MQTT only (owner). The
  `udp.notifications` config pointing at it is stale and should be turned off rather than permitted.
- **`DRAFT/` directory, numeric filename prefixes and the `.STAGE3` suffix removed.** They matched
  nothing in this repo, and worse, implied the danger was quarantined in the last file. It is not —
  see below.
- **All selectors verified against the running clusters** (2026-08-26): the four app labels, `mongodb`,
  `emqx`, `alloy-receiver`, `k8s-app=kube-dns`, and the namespace `metadata.name` labels. server1 was
  checked too and is identical, so its copy is a straight duplicate.

> **`NetworkPolicy.dns-egress.yaml` is the cliff, not `default-deny`.** It uses `podSelector: {}` with
> `policyTypes: [Egress]`, and in Kubernetes a pod selected by *any* egress policy denies all egress
> that does not match a rule. The moment that file syncs, every pod in the namespace can reach DNS and
> nothing else. `NetworkPolicy.default-deny.yaml` adds ingress denial and covers pods no other policy
> selects — it is not the switch. Apply the set as one atomic unit, with audit mode already on.

---

## Stage 2 — the audit-mode procedure

Verified against the **actually deployed version: Cilium 1.19.2** (chart `cilium-1.19.2`, image
`quay.io/cilium/cilium:v1.19.2`), not assumed.

Audit mode evaluates policy and logs what *would* have been dropped, while still forwarding it. It is
what makes Stage 2 a dry run instead of a gamble.

### Relevant current settings

Confirmed via `cilium-dbg config --all`:

```
PolicyAuditMode                   : Disabled
EnablePolicy                      : default
EnableK8sNetworkPolicy            : true
EnableCiliumNetworkPolicy         : true
PolicyVerdictNotification         : Enabled
BPFEventsPolicyVerdictEnabled     : true
PolicyCIDRMatchMode               : []
```

`PolicyVerdictNotification` and `BPFEventsPolicyVerdictEnabled` are already on, so verdict events will
flow as soon as there is a policy to evaluate. Nothing needs enabling for observability.

### Two ways to turn it on — pick the second

**Option A — per endpoint (ephemeral).** The documented approach:

```bash
CTX=admin@server1                 # server1 first: it is the cluster with live device traffic
POD=$(kubectl --context $CTX -n production get pod -l app.kubernetes.io/name=miot-bridge-api \
        -o jsonpath='{.items[0].metadata.name}')
EP=$(kubectl --context $CTX -n production get cep "$POD" -o jsonpath='{.status.id}')
CILIUM=$(kubectl --context $CTX -n kube-system get pod -l k8s-app=cilium \
        -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CTX -n kube-system exec "$CILIUM" -c cilium-agent -- \
  cilium-dbg endpoint config "$EP" PolicyAuditMode=Enabled
```

`PolicyAuditMode` is confirmed present in `cilium-dbg endpoint config --list-options` on 1.19.2.

**Do not use this for the full-day run.** It is per-endpoint and ephemeral: it resets when the Cilium
pod restarts, **and the endpoint ID changes whenever the application pod restarts** — so a rollout or
an OOM silently drops you out of audit mode and into enforcement. Across 8 workloads × 2 namespaces ×
2 clusters it is also 32 endpoint IDs to chase.

**Option B — cluster-wide via Helm (persistent). Use this one.**

```yaml
# iac/clusters/helm-values/cilium.yaml
policyAuditMode: true
```

Confirmed a real chart value in `cilium-1.19.2`. Two things make this safe despite sounding broad:

- **Cilium is Terraform-managed, not ArgoCD** — `iac/modules/platform/main.tf`, `helm_release.cilium`.
  Editing anything under `gitops/` will not take effect. Same constraint as task 0.1.
- **Cluster-wide audit mode is not cluster-wide risk.** With `EnablePolicy: default`, only endpoints
  *selected by some policy* are enforced at all. Since the only policies will be the ones targeting
  `production`/`sandbox`, those are the only endpoints audit mode can affect.

It survives restarts, needs no endpoint bookkeeping, and is one revert to undo. Cost: applying it
restarts the Cilium agents, briefly disrupting pod networking on that node — the same interruption
task 0.1 describes.

### Reading the verdicts

Two views of the same events. Hubble is easier; `cilium-dbg` is the one the brief names.

```bash
# Anything that WOULD have been dropped, cluster-wide:
kubectl --context $CTX -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --type policy-verdict --verdict AUDIT --follow

# Same, scoped, and durable enough to diff later:
kubectl --context $CTX -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --type policy-verdict --verdict AUDIT \
    --namespace production --output json > audit-production.json

# The brief's form, per endpoint:
kubectl --context $CTX -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg monitor --type policy-verdict --related-to "$EP"
```

An audited flow reads `action audit, match none` in `cilium-dbg`, and `policy-verdict:none AUDITED` in
Hubble. **Every hit is either a missing rule or a flow that should not exist — resolve each one
explicitly, in writing.** A clean run means zero AUDIT verdicts, not "a few we decided to ignore".

### Run it for at least a full day — and force the rare flows

A quiet day proves less than it appears, because the three flows most likely to be missing are exactly
the ones that do not happen on their own. Before calling audit mode clean, **actively exercise**:

- [ ] a CHMI request through `interactive-map-feeder-api` (idle ~9 days as of writing)
- [ ] a `miot-spec.org` lookup — the device-registration path (**no calls in 30 days**)
- [ ] a Loxone UDP notification — needs a device property to actually change
- [ ] a pod restart, to force fresh DNS resolution through the policy

If any cannot be exercised, record that and accept the risk knowingly rather than by omission.

### A subtlety that will hide breakage

Over the whole 18-minute window, **server2's app pods opened no new connections at all** — every
MongoDB, EMQX and OTLP flow rode a connection established before the capture began. Because Cilium
tracks connections in conntrack, established connections generally survive a policy change.

So a bad policy on server2 would likely look **completely fine at apply time** and only break later, at
the next reconnect, restart or rollout — decoupled from the change that caused it. Do not read "still
healthy five minutes after apply" as success. Restart a pod and watch it come up clean.

### Rollback

Removing a policy takes effect without a pod restart:

```bash
kubectl --context $CTX -n production delete networkpolicy default-deny
```

Reverting `policyAuditMode` is a Terraform apply and restarts the agents again.

---

## Baseline for comparison

Across the full window, on both clusters, there were **zero** non-`FORWARDED` verdicts touching
`production` or `sandbox`, and zero existing policy-verdict events (no policies select those pods yet).
The baseline is clean, so any drop observed after Stage 2 begins is attributable to the new policy
rather than to pre-existing noise.

---

## What I could not determine

Listed plainly, because Stage 3 gets applied on the strength of this document.

1. **DNS was never observed from any server2 app pod**, and never from `qr-manager-api`,
   `interactive-map-feeder-api` or `qr-manager-ui` on either cluster. The DNS rule rests on
   construction, not observation. It is certainly correct — but it is not *verified*, and it is the
   rule whose absence causes the classic outage.
2. **The Loxone UDP notification flow was never observed**, on either cluster. Config-derived only.
   Destination, port and protocol come from `udp.notifications.address`; nothing confirms the
   controller is listening or that the path currently works.
3. **`miot-spec.org` has not been called in the full ~30-day Prometheus retention.** The rule is
   config-derived. I could not confirm the port is 443 by observation — it is taken from the
   configured `https://miot-spec.org/miot-spec-v2` base URL.
4. **The observation window is ~18 minutes, not the "full poller cycle, longer is better" the brief
   asks for.** The 5s device poll cycle is covered many times over; anything hourly or daily is not.
   The ~30-day app-metrics window compensates **only for outbound HTTP with a `server_address`
   label** — it does not cover non-HTTP protocols, inbound flows, or any workload that does not emit
   OTel. Treat the Hubble half of this inventory as a good sample, not a complete census.
5. **Hubble L7 DNS visibility is not enabled**, so I could not see *which names* pods resolved — only
   that they talked to CoreDNS. Confirming that a pod resolves exactly the expected set of names needs
   either a DNS-visibility policy or the `40-` CNP in place.
6. **Hubble's Prometheus metrics carry no identity labels.** `hubble_flows_processed_total` has only
   `protocol`/`verdict`/`type`/`subtype` — no source or destination namespace — because no
   `labelsContext` is configured. Grafana therefore could not extend the flow window at all.
   *(Recommendation, not done: adding `labelsContext` with source/destination namespace to the Cilium
   Helm values would make exactly this task cheap next time, and would give the audit-mode step a
   dashboard instead of a log tail.)*
7. **Server3 was not surveyed.** Out of scope per the brief, but it hosts `argocd`, `openbao`,
   `monitoring` and the cross-cluster OTLP receiver, so it is the natural next target and its flow set
   is entirely unmapped.
8. **The existing `mongodb/mongodb` NetworkPolicy was not analysed for interaction** with the drafts.
   It permits ingress on 27017 from any source, so it should not conflict — but two policies selecting
   overlapping pods is exactly where surprises live, and this was not tested.

## Maintaining these policies — read before adding anything to an app

**This is the section that keeps the policies from becoming a trap.** Every constraint below is a way to
make a working app fail in-cluster with a symptom that points nowhere near the network: a timeout deep
inside a client library, no error log, nothing in the app's own telemetry. If you add one of these
without the matching rule, you will debug the wrong thing.

### Adding a new in-cluster dependency

Any new pod-to-pod destination — another database, a cache, a second broker, one app calling another —
is denied by default once these policies are enforced. Nothing in the `iot-miniservers` repo mentions
this: `AGENTS.md`, `docs/Deployment.md`, `docs/KNOWLEDGE.md`, the `add-workspace-member` skill and both
`http-provider` READMEs have **zero** references to network policy (verified 2026-08-26). So the
knowledge lives here, and only here.

**The procedure:**

1. Open the calling app's file:
   `gitops/k8s-manifests/<cluster>/network-policies/<namespace>/NetworkPolicy.egress-<app>.yaml`.
2. Add an `egress` entry with a `namespaceSelector` on `kubernetes.io/metadata.name` plus a
   `podSelector` on `app.kubernetes.io/name`, and the port.
3. **Verify both selectors against the running cluster before merging.** This is the step that actually
   matters — a selector that matches nothing produces a policy that looks right and silently denies:

   ```sh
   # does the destination carry the label the rule selects?
   kubectl -n <dest-namespace> get pods -l app.kubernetes.io/name=<dest> --no-headers | wc -l
   # does the namespace carry the metadata label?
   kubectl get ns <dest-namespace> -o jsonpath='{.metadata.labels.kubernetes\.io/metadata\.name}'
   ```

   Both must be non-empty. All current selectors were verified this way on 2026-08-26:
   `mongodb`, `emqx`, `alloy-receiver`, `k8s-app=kube-dns`, and the four app labels.
4. Repeat for `sandbox`, and for the other cluster.

**Why this is worth documenting rather than loosening:** unlike per-host internet egress (removed, see
below), in-cluster destinations are few, stable, and changing them is exactly the lateral-movement
boundary the policies exist to draw. The constraint earns its keep; it just has to be findable.

### Outbound internet — deliberately NOT constrained per host

An earlier revision pinned each third-party host with Cilium `toFQDNs`
(`intranet.chmi.cz`, `opendata.chmi.cz`, `miot-spec.org`), derived from the apps' own OTel metrics.
**Removed 2026-08-26**, replaced by `NetworkPolicy.egress-internet.yaml`: `0.0.0.0/0` minus the private
ranges, on 443/80, for every pod in the namespace.

The reason is not that the FQDN rules were wrong — they were accurate. It is that adding an external API
is a change in `iot-miniservers` (`externalApis` config) while the matching egress rule would have been a
change in *this* repo, undocumented in every place a developer looks. Documenting it would have been
shipping a footgun with a warning label. The security given up is close to nothing: the in-cluster and
LAN rules carry the value, and a container that can already reach the whole LAN gains little from being
denied outbound HTTPS. Removing it also drops Cilium's DNS proxy from the path of every lookup.

**Adding a new external API therefore needs no policy change** — provided it is on 443 or 80.

### The one remaining port constraint

`NetworkPolicy.egress-internet.yaml` allows **TCP 443 and 80 only**. An external dependency on any other
port is denied. Rare in practice — every HTTP API qualifies — and it keeps a compromised container from
opening arbitrary outbound connections. If that trade stops being worth it, widen the rule rather than
adding per-port exceptions; the lesson from the FQDN rules is that a rule nobody can find is worse than a
rule that is slightly too broad.

### Inbound ports — no new ones needed, but UDP 4000 is unresolved

`CiliumNetworkPolicy.host-ingress.yaml` allows **TCP 4000** (the Ts.ED APIs) and **TCP 80** (the nginx
UIs). Those are fixed by the shared chart's `CONTAINER_PORT` convention, so a new app needs no change.

**`miot-bridge-api`'s UDP 4000 ingress is not covered, and that is an open decision, not an oversight.**
The path is still fully wired — `udpIngress.entrypoint: udp-miot-prod` / `-sbx` in the app values,
matching Traefik entrypoints on server1 and server2, an `IngressRouteUDP` from the chart, and the app
logs `UDP_LISTENER_STARTED UDP listener started on port 4000`. But no inbound UDP was observed, and the
owner confirms **Loxone now consumes MQTT only** (2026-08-26).

Two coherent resolutions — pick one before enforcing, do not leave it ambiguous:

- **If the UDP path is dead (expected):** remove `udpIngress` from
  `gitops/helm-values/apps/miot-bridge-api/{production,sandbox}.yaml`, remove the `udp-miot-prod` /
  `udp-miot-sbx` entrypoints from `gitops/helm-values/server{1,2}/traefik.yaml`, and turn off
  `udp.enabled` plus `udp.notifications` in the app's config block. The policy is then correct as
  written. This is the same stale-config cleanup as the `udp.notifications.address:
  192.168.1.140:50450` entry, which also points at a Loxone path no longer in use.
- **If UDP must keep working:** add `port: "4000", protocol: UDP` to the `toPorts` list in
  `CiliumNetworkPolicy.host-ingress.yaml` in both namespaces and both clusters.

Enforcing without deciding means the UDP listener keeps running, keeps looking healthy, and silently
receives nothing.

## Follow-ups this surfaced

- Tighten `mongodb/mongodb`: it currently accepts 27017 from anywhere in the cluster.
- Decide whether `sandbox` should be talking to the real Loxone controller and real devices at all.
  Right now it is not a safe place to experiment.
- Add `hubble.metrics.labelsContext` (source/destination namespace) to the Cilium Helm values.
- The `miot-bridge-api` UDP listener has a Service but no route — confirm whether it is meant to be
  reachable, or is vestigial.

---

## Stage 3 — enforced on server2 (2026-08-26)

Applied sandbox first, verified, then production. **Zero `DROPPED` events in either namespace**
across the full Hubble ring buffer, before and after a rolling restart of every workload.

### What was actually proven, per rule

The survey could not observe DNS, CHMI or LAN egress on server2 at all. Enforcement plus a forced
restart turned every one of those from "argued from construction" into an observed verdict — except
the LAN rule, which remains unexercisable here.

| Rule | Evidence under enforcement |
| --- | --- |
| `allow-host-ingress` (CNP) | `(host) -> sandbox/…:4000 ALLOWED`, `…:80 ALLOWED`. Covers kubelet probes **and** Traefik — confirmed `hostNetwork: true`, pod IP == node IP == `192.168.1.201` |
| `allow-dns-egress` | `sandbox/interactive-map-feeder-api -> kube-system/coredns:53 ALLOWED (UDP)` — **the first DNS ever observed from a server2 app pod.** Also from both restarted APIs |
| `allow-egress-internet` | `sandbox/interactive-map-feeder-api -> 90.183.101.91:443 (world) ALLOWED` and `.75:443`. Both CHMI hosts. The `0.0.0.0/0 except` RFC1918 form correctly matches the `world` identity |
| `allow-egress-miot-bridge-api` | `-> mongodb/mongodb-0:27017 ALLOWED`, `-> iot/emqx-0:1883 ALLOWED`, `-> monitoring/…alloy-receiver:4318 FORWARDED`, all from post-restart pods |
| `allow-egress-qr-manager-api` | `-> mongodb/mongodb-0:27017 ALLOWED`; app log `Connect to mongo database: default` after restart, both namespaces |
| `allow-egress-interactive-map-feeder-api` | OTLP proven end-to-end, not just permitted — see below |
| `allow-egress-lan-miio` | **Still unexercised.** server2 has zero registered devices; both pods log `Loaded 0 subscription(s) across 0 device(s)`. This rule is verified on server1 only, and only once a device poll happens there |
| `default-deny` | Applied 2–3 s *after* the allowlist, by design (see sync-wave note below). Nothing broke in the gap |

### OTLP proven end-to-end, not merely permitted

A `FORWARDED` verdict proves the packet was allowed, not that the data landed. Probe
`probe-otlp-b5cd5a24` / trace `3d1d82d14f763b5a0b06365f1a628b2b` closed the loop:

```
response      PASS  200 in 22ms
loki:traefik  PASS  TraceId matches the minted id
loki:app      PASS  from the post-restart pod api-iot-interactive-map-feeder-api-bdc44b947-5n67r
tempo         PASS  traefik (2 spans) + interactive-map-feeder-api (9 spans)
```

Tempo holding the app's spans means the app's OTLP reached the in-cluster Alloy receiver **and**
Alloy's cross-cluster hop to server3 still works — confirming correction #1: default-deny on
production/sandbox cannot break the trace path, because that hop belongs to `monitoring`.

### The restart was the test, not the apply

This document warns that server2's pods reuse long-lived connections, so a bad policy would look
fine at apply time and break at the next reconnect. That is why every workload in both namespaces
was rolling-restarted **after** the policies were enforced. All came up `1/1 Ready`, with
`Connect to mongo database` and `MQTT client connected` in the logs. Applying and observing nothing
would have proven nothing.

The MQTT connect/disconnect flap reappeared for ~20 s after boot and then stopped, in both
namespaces — matching the pre-existing behaviour recorded above. Zero drops confirms the policy is
not its cause.

### CHMI on server2 is live — correction to this document

The table above says server2 had **never** called CHMI in 30 days of retention. That was read from
metrics; it is wrong as a statement about capability. A pre-policy baseline probe returned
`200, 769269 bytes` from `/v1/data-sources/radar/image` in **both** namespaces, and it still does
under enforcement. The path is live on server2 and gave the rollout an exact pre/post oracle
instead of the unexercisable flow this document expected.

### Two changes made during review

1. **`default-deny` now carries `argocd.argoproj.io/sync-wave: "1"`.** Everything else is wave 0.
   ArgoCD orders custom resources after core ones within a wave, so without this the core
   `NetworkPolicy` ingress deny could land while `CiliumNetworkPolicy.host-ingress` had not —
   an ingress blackout taking kubelet probes and Traefik down together for the length of the gap.
   Observed working: allowlist at 15 s, `default-deny` at 12 s.
2. **The ArgoCD Applications are manual-sync**, unlike every other Application in this repo. The
   documented rollback is `kubectl delete networkpolicy`, and `selfHeal` would undo exactly that on
   the next reconcile.

### Verified against the live cluster during review

Every selector was checked against a real object rather than read: all four app pod labels, the
`kube-dns` / `mongodb` / `emqx` / `alloy-receiver` selectors, and `kubernetes.io/metadata.name` on
every namespace. Two findings that would each have been silent outages had they gone the other way:

- **`alloy-receiver` is not `hostNetwork`** (pod IP `10.244.0.32`). A `podSelector` reaches it. Had
  it been host-networked, the OTLP rule would have matched nothing and all telemetry would have
  stopped at the next reconnect.
- **The existing `mongodb/mongodb` NetworkPolicy does not conflict** — `ingress: [ports: 27017]`
  with no `from` is allow-from-anywhere, and `egress: [{}]` is allow-all. Gap 8 above is closed.

Also confirmed inert: `api-iot-miot-bridge-api-udp` (ClusterIP `:4000/UDP`) has no ingress rule, and
nothing can reach it — the `UDPRoute` CRD is not installed at all and the Gateway listens on HTTP/80
only.

### Before server1

server1 is the cluster where a mistake is expensive: one registered device, six subscriptions, live
miIO polling every 5 s. Two things to settle first.

1. **Turn off `udp.notifications` in the miot-bridge-api values.** Both namespaces still set
   `udp.notifications.enabled: true` → `192.168.1.140:50450`, and the policy set deliberately does
   not permit it, on the owner's statement that Loxone consumes MQTT only. On server2 that
   disagreement is untestable — no devices, so no notifications fire. On server1 it fires on every
   property change and will be dropped. Either the config goes to `false` or the flow gets a rule;
   leaving the two disagreeing is what makes it a surprise later.
2. **Write down the ports 80/443 constraint** in the app repo, as
   `NetworkPolicy.egress-internet.yaml` itself asks. An external dependency on any other port will
   fail in-cluster with no local symptom.

Then: add server1 to the generator list in `NetworkPolicies.yaml`, sync sandbox, restart, verify,
and only then production.

---

## Stage 3 — enforced on server1 (2026-08-28)

Same order as server2: sandbox, verify, restart, production, restart. **Zero drops in either
namespace.** server1's policy set is a byte-identical copy of server2's — `diff -r` between the
two directories is empty and must stay that way.

server1 was checked against the assumptions the policies encode rather than assumed to mirror
server2: same pod labels, Traefik `hostNetwork` on `192.168.1.200`, `alloy-receiver` **not**
host-networked (`10.244.0.28`), `PolicyCIDRMatchMode` empty, and `mongodb/mongodb` the only
pre-existing policy.

### The LAN rule finally got exercised

`allow-egress-lan-miio` had never been tested anywhere — server2 has no registered devices, so
the flow does not exist there. server1 has one device with six subscriptions polling every 5 s,
and it survived enforcement:

```
production/api-iot-miot-bridge-api-56685c46c8-bp68z:57496 -> 192.168.1.85:54321 (ID:16777217)
  policy-verdict:none ALLOWED (UDP)
production/api-iot-miot-bridge-api-56685c46c8-bp68z:57496 <- 192.168.1.85:54321 (ID:16777217)
  to-endpoint FORWARDED (UDP)
```

from a pod created *after* the policy was enforced, still logging
`Loaded 6 subscription(s) across 1 device(s)`.

Worth noting the identity change: before the policy the device was `(world)`; afterwards it is
`(ID:16777217)`, a CIDR identity Cilium allocated for the `192.168.1.0/24` prefix named in the
rule. That is the visible proof the `ipBlock` is what matches, not a fallback.

The device's replies arrive on the conntrack entry the egress opened, so `default-deny` on
ingress does not need a matching inbound rule. The 5 s poll interval keeps that entry alive
comfortably.

### Loxone: the disagreement is resolved

The UDP notification channel to `192.168.1.140:50450` was never consumed, and was removed from
the app config entirely on 2026-08-28 (see the miot-bridge commit) rather than left enabled and
silently dropped. Confirmed on server1, the only cluster where it could ever have fired: zero
flows to `.140` after the change, while the device poll continues.

### Full verdict matrix, server1 production, post-restart

Every rule exercised, all `FORWARDED`, nothing dropped:

| From | To | Port |
| --- | --- | --- |
| `miot-bridge-api` | both CoreDNS pods | UDP 53 |
| `miot-bridge-api` | `emqx-0` | TCP 1883 |
| `miot-bridge-api` | `mongodb-0` | TCP 27017 |
| `miot-bridge-api` | `alloy-receiver` | TCP 4318 |
| `miot-bridge-api` | `192.168.1.85` (world) | **UDP 54321** |
| `qr-manager-api` | CoreDNS, `mongodb-0` | UDP 53, TCP 27017 |
| `interactive-map-feeder-api` | CoreDNS, `alloy-receiver`, internet | UDP 53, TCP 4318, TCP 443 |
| host | all three APIs | TCP 4000 |
| host | `qr-manager-ui` | TCP 80 |

---

## The gap this rollout left: apiserver egress — fixed 2026-08-28

**Pod egress to the Kubernetes apiserver was denied.** Found after both clusters were enforced,
planned in [`2026-08-28-netpol-apiserver-egress.md`](./2026-08-28-netpol-apiserver-egress.md),
and fixed by `CiliumNetworkPolicy.egress-apiserver.yaml` in all four namespaces. The diagnosis
below is kept because the mechanism is the reusable part.

`10.96.0.1` is inside the service CIDR, inside the `10.0.0.0/8` entry in the `except` list of
`NetworkPolicy.egress-internet.yaml`, and no other rule grants it. Verified from inside a
`qr-manager-api` pod on server1/sandbox, with controls to isolate it:

```
kubernetes.default.svc:443  => TIMEOUT (exit 28)
10.96.0.1:443               => TIMEOUT (exit 28)
opendata.chmi.cz:443        => 200        <- internet rule works
mongodb:27017               => open       <- in-cluster rule works
```

DNS resolved, so it is the connection being dropped rather than the name.

**Nothing is broken today** — no workload calls the apiserver, which is why every drop counter
stayed at zero through both rollouts. It matters for the auth work, where verifying
ServiceAccount tokens means fetching JWKS from `kubernetes.default.svc`.

The Hubble drop shows exactly why an `ipBlock` would not fix it:

```
sandbox/api-iot-qr-manager-api:40768 <> 192.168.1.200:6443 (host) Policy denied DROPPED (TCP Flags: SYN)
```

The ClusterIP is DNAT'd to the node's apiserver, so the destination carries the **`host`**
identity — and CIDR selectors do not match `host` while `PolicyCIDRMatchMode` is empty. This is
the same trap `CiliumNetworkPolicy.host-ingress.yaml` documents for ingress; it was simply not
carried across to egress. The supported form is `toEntities: [kube-apiserver]`.

### The fix, and what it proves

`CiliumNetworkPolicy.egress-apiserver.yaml`, `toEntities: [kube-apiserver]`, in all four
namespaces. Two decisions worth recording:

**Both 443 and 6443.** 443 is what a pod dials; 6443 is what the packet carries once the
ClusterIP is translated, and is the port that actually appeared in the drop. Listing both makes
the rule correct on either side of the translation and grants nothing extra — the entity is the
apiserver either way.

**`endpointSelector: {}`, not per-app**, matching how `dns-egress` is scoped. Every
service-to-service path in the auth design verifies tokens the same way, so a per-app rule would
have to be revisited for every service added later, with a timeout deep inside an HTTP client as
the only symptom. That is the footgun this repo already declined to ship once, in
`NetworkPolicy.egress-internet.yaml`. The grant is small: `automountServiceAccountToken: false`
means these pods hold no cluster credentials, so an unauthenticated request gets a 401.

Verified in **all four namespaces**, from a throwaway pod in the namespace — which the
namespace-wide selector covers exactly as it covers the app pods:

| Check | Before | After |
| --- | --- | --- |
| `jwks`, insecure | timeout (exit 28) | **HTTP 401** |
| `jwks`, TLS verified against `kube-root-ca.crt` | — | **HTTP 401** |
| control — `opendata.chmi.cz:443` | 200 | 200 |
| control — `1.1.1.1:8443` | dropped | **still dropped** |

The last row is the one that matters as much as the first: it proves the new rule did not widen
general egress. The 80/443 restriction still holds.

### The CA question, answered

Use the **`kube-root-ca.crt` ConfigMap**. Kubernetes publishes it into every namespace, it
carries the same CA bundle, and it keeps `automountServiceAccountToken: false` intact — which
the projected-volume alternative does not.

Proven rather than assumed: `curl --cacert /ca/ca.crt https://kubernetes.default.svc/openid/v1/jwks`
completes the TLS handshake and returns the apiserver's own `Status` object with `"code": 401`.
A verifying client therefore has a working trust root without any ServiceAccount change.

Mounting it is an application-chart change and deliberately **not** done here — it belongs with
the auth work that consumes it. What is done here is the part that had to be rolled out to two
clusters before that work could start.
