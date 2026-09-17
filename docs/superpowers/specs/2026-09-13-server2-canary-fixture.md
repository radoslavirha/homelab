# server2 as a deliberate canary, after the IoT estate leaves

**Status:** open, not started. Deferred by the user 2026-09-13 — *"I would skip for now, just prepare
a short spec, agents will dig."* Nothing is broken; this is about coverage that is about to be lost.

**Trigger:** the decision on 2026-09-13 to remove the entire IoT estate from server2, which will host
an LLM instead. Tracked in section 2, "What the server2 IoT removal left behind", of
[`../plans/2026-09-13-open-work.md`](../plans/2026-09-13-open-work.md).

---

## The problem

server2 is the canary for every platform upgrade — order is always server2 → server1 → server3. That
worked this week for Longhorn 1.12.1, Gateway API 1.6.2, Cilium 1.20.1, Traefik 41.5.0, Talos v1.13.10
and the Terraform providers. It worked because server2 happened to run a copy of the IoT estate, so an
upgrade there exercised real volumes, routes, policies and secrets.

Removing the IoT estate removes that, and it lands hardest on the two riskiest upgrade types.
Measured on server2, 2026-09-13:

| | Before | After |
|---|---|---|
| Longhorn volumes | 3 | **0** |
| CiliumNetworkPolicies | 4 | **0** |
| NetworkPolicies | 17 app + 6 longhorn-system | 6 longhorn-system |
| ExternalSecrets | 16 | 3 |
| HTTPRoutes | 13 | 3 dashboards |

The Longhorn engine upgrade was verified by watching volumes stay `attached`/`healthy` through the
swap — with zero volumes there is nothing to watch. Cilium enforcement was verified by diffing
enforcement counts and BPF policy-map entries against `production`/`sandbox` — with zero policies that
check passes vacuously.

**And server3 already has zero CiliumNetworkPolicies.** After the removal, server1 is the only cluster
carrying any, so the only place a CNI policy regression can surface is the cluster running the real
Loxone estate.

## Is the `sandbox` namespace not enough?

**It is exactly the right place — that is the answer, not an objection.** There is no need for a new
namespace called "canary". `sandbox` already exists on server2, already has NetworkPolicies and
CiliumNetworkPolicies targeting it, and is already wired into the ApplicationSet matrix as an `env`.

The problem is not the namespace, it is that **after the removal `sandbox` on server2 will be empty**.
So the work is: keep the namespace and its policies, and put a small synthetic workload in it in place
of the four apps that are leaving.

That is strictly cheaper than inventing a parallel structure, and it means the policy layer keeps
being exercised by the same objects that already exist.

## What it needs to cover

Coverage should be **designed**, not inherited. Today's coverage has a hole that is already visible:
neither server1 nor server2 has a wildcard CiliumNetworkPolicy, so neither showed Cilium 1.20's
`reserved:aggregate-*` bucket materialization — only server3 did, and only because its policy happens
to allow ingress from any source.

Minimum set, roughly 100 lines of YAML and no real data:

1. **A StatefulSet with a Longhorn PVC**, a few hundred MB, running something that writes. Restores
   the volume-attach signal for Longhorn manager *and* engine upgrades. Engines do not follow the
   manager — `concurrent-automatic-engine-upgrade-per-node-limit` is `0` — so the engine swap must be
   observable somewhere.
2. **One HTTPRoute on a real hostname**, answering 200 through the Traefik Gateway. The Traefik
   failure mode was 404s while the Gateway read `Accepted`/`Programmed` with 9 attached routes.
   Status is not the signal; a request is.
3. **One ExternalSecret**, so the ESO → Traefik HTTPRoute → server3 OpenBao path stays exercised from
   a second cluster. Check `status.refreshTime`, not the `SecretSynced` badge — it is stale for up to
   `refreshInterval` (1h).
4. **Two CiliumNetworkPolicies: one naming specific entities, one using a wildcard.** The wildcard is
   the point; see above.
5. **One deliberately denied path** — a port outside the policy, verified to time out. This is the
   single most valuable item. Testing only allowed paths cannot distinguish "still enforcing" from
   "failed open".
6. *Optional:* one TCP passthrough port, if any of Traefik's 1883/8883/27017 entries are kept.

## What the LLM workload covers for free

Model weights mean a large Longhorn volume — a heavier storage test than 25Gi of InfluxDB ever was.
Once it exists, treat it as covering the storage axis and keep the synthetic PVC small. Do not size
the fixture as though it were the only storage on the cluster.

## The other half: make the comparison mechanical

Every verification during the 2026-09-12/13 upgrade run had the same shape — capture N before, capture
N after, diff. It was done by hand each time and depended on remembering which N mattered.

Worth a `scripts/preflight.sh <cluster>` that dumps, in a diffable form:

- node `bootID` *(the correct probe for "did this reboot?" — not uptime, not pod age)*
- pod counts by phase, and any pod not `Running`/`Succeeded`
- Longhorn volume states, `currentImage`, and engine image refcounts
- Cilium enforcement counts (`both`/`ingress`/`none`) and BPF policy-map entry counts per endpoint
- ESO `status.refreshTime` per ExternalSecret
- every HTTPRoute hostname's actual HTTP status code

Then "compare against baseline" is a `diff`, not a memory exercise. This is useful **independently of
the fixture** and could land first.

## Rejected: a throwaway VM cluster

Considered and rejected 2026-09-13. It would not reproduce what actually surprised us — NIC names
(`eno1` vs `enp0s31f6`), disk selectors, the KubePrism wiring (`k8sServiceHost: localhost`,
`k8sServicePort: 7445`), or single-control-plane reboot behaviour. High effort, wrong fidelity.

## Open questions for whoever picks this up

- Does the fixture live in the existing `sandbox` ApplicationSet matrix, or as its own Application?
  The matrix generator is `{cluster} × {env}`, and server2 is being removed from it — so reusing it
  means adding server2 back for one app only, which may be worse than a standalone Application.
- Should the same fixture also run on server3? It has zero CNPs today, so the same blind spot exists
  there, and server3 is the cluster where a mistake costs the most.
- Is a synthetic HTTPRoute hostname worth a real DNS record and certificate SAN, or should it reuse an
  existing wildcard?
