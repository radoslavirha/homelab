---
name: network-egress
description: "Change what app pods in production/sandbox are allowed to reach on the network. Use when: an app gained a dependency the default-deny policy does not permit (a non-80/443 port, a LAN host, a new in-cluster service, a new inbound port), a call times out in-cluster but works locally, or Hubble shows Policy denied DROPPED. Also use when adding an app to those namespaces."
argument-hint: "What needs to reach what, e.g. 'qr-manager-api needs redis.iot:6379' or 'interactive-map-feeder needs an API on 8443'"
---

# network-egress

`production` and `sandbox` on server1 and server2 are default-deny. This skill changes the
allowlist without turning a config edit into an outage.

Reference for what is allowed today: [`docs/network-egress.md`](../../../docs/network-egress.md).
Policies: `gitops/k8s-manifests/<cluster>/network-policies/<namespace>/`.

## Two facts that decide everything

**1. The clusters' policy sets are byte-identical.** `diff -r` between
`server1/network-policies` and `server2/network-policies` is empty and must stay empty. Current
behaviour differs between the clusters only until someone registers a device on server2 — so
tailoring a rule to what one cluster happens to do today is how the other cluster ends up
missing it. **Every edit is made twice.**

**2. A green apply proves nothing.** Cilium tracks connections in conntrack, so established
connections survive a policy change. A broken policy looks completely fine at apply time and
breaks at the next reconnect, restart or rollout — decoupled from the change that caused it.
**The restart is the test.**

## Procedure

### 1. Confirm the policy is actually the cause

Do not skip to editing. Reproduce the failing call while watching:

```bash
kubectl --context admin@server1 -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace production --type drop --follow
```

`Policy denied DROPPED` with the destination you expect = confirmed. Nothing = the policy is
not your problem; stop here.

### 2. Pick the right file

| Need | File |
| --- | --- |
| a non-80/443 internet port | `NetworkPolicy.egress-internet.yaml` — add to `ports` |
| a new in-cluster service | the app's `NetworkPolicy.egress-<app>.yaml` |
| a new LAN host or port | `NetworkPolicy.egress-lan-miio.yaml`, or a new file if unrelated to miIO |
| a new inbound port | `CiliumNetworkPolicy.host-ingress.yaml` |
| a whole new app | a new `NetworkPolicy.egress-<app>.yaml`, both namespaces |

Prefer **plain `NetworkPolicy`**. The one deliberate exception is `host-ingress`: all ingress
arrives from the node, and an `ipBlock` cannot match Cilium's `host` identity while
`policyCIDRMatchMode` is unset — such a rule looks correct, passes review, and matches nothing.

Scope in-cluster rules with `namespaceSelector` + `podSelector`, not IPs. Verify the selector
matches something real before trusting it:

```bash
kubectl --context admin@server1 -n <ns> get pods -l <your-selector> --show-labels
```

An empty result means the rule will silently match nothing.

### 3. Edit, then mirror

Make the change under `server1/`, copy the file to `server2/`, and prove they still match:

```bash
diff -r gitops/k8s-manifests/server1/network-policies \
        gitops/k8s-manifests/server2/network-policies && echo IDENTICAL
```

Say **why** in a comment in the file. These files are read during incidents by someone who did
not write them; a rule whose reason is not written down gets deleted by the next person.

Update the table in `docs/network-egress.md` in the same commit. A rule the reference page does
not mention is a rule the next developer will trip over exactly as you just did.

### 4. Validate before syncing

```bash
kubectl --context admin@server1 apply --dry-run=server \
  -f gitops/k8s-manifests/server1/network-policies/<ns>/
```

### 5. Sandbox first, then production

The Applications are **manual-sync** on purpose — `selfHeal` would undo the emergency rollback.

```bash
# sandbox
kubectl --context admin@server3 -n argocd patch app network-policies-server1-sandbox \
  --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

ArgoCD does not reconcile on its own here. If the Application still shows `Synced` after a
push, hard-refresh it first:

```bash
kubectl --context admin@server3 -n argocd annotate app <app> \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 6. Restart, and watch it come up clean

This is the step that makes the run worth anything.

```bash
kubectl --context admin@server1 -n sandbox rollout restart deploy/<deployment>
kubectl --context admin@server1 -n sandbox rollout status deploy/<deployment>
```

Then confirm **zero drops** and that the new flow is actually permitted:

```bash
kubectl --context admin@server1 -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace sandbox --type drop --last 4000        # want: empty
kubectl --context admin@server1 -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace sandbox --type policy-verdict --last 4000 | grep <destination>
```

Only then repeat for `production`, and for the other cluster.

For end-to-end proof that a path works rather than merely being permitted, use the
**`probe-traffic`** skill — V3 (in-pod) is the correct vantage for egress, because it inherits
the app pod's Cilium identity.

## Rollback

Immediate, no pod restart:

```bash
kubectl --context admin@server1 -n production delete networkpolicy default-deny
```

For full un-restriction also delete `allow-dns-egress` — `podSelector: {}` makes it, not
`default-deny`, the file that actually arms egress enforcement.

## Do not

- **Do not edit one cluster only.** The next incident will be on the other one.
- **Do not widen `allow-egress-internet` to all ports** to make a single dependency work. The
  port restriction is the remaining value in that rule; add the one port.
- **Do not use `ipBlock` for in-cluster or node traffic.** Pod IPs churn, and CIDR selectors do
  not match the `host`/`remote-node` identities on these clusters.
- **Do not enable Cilium `policyAuditMode` as a safety net.** It forwards everything, so it
  cannot detect the conntrack problem above — the failure mode that actually bites here. A
  sandbox rollout with a restart tests more, faster, and rolls back in one command.
