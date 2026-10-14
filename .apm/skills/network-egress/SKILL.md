---
name: network-egress
description: "Change what app pods in production/sandbox are allowed to reach on the network. Use when: an app gained a dependency the default-deny policy does not permit (a non-80/443 port, a LAN host, a new in-cluster service, a new inbound port), a call times out in-cluster but works locally, or Hubble shows Policy denied DROPPED. Also use when adding an app to those namespaces."
argument-hint: "What needs to reach what, e.g. 'qr-manager-api needs redis.iot:6379' or 'interactive-map-feeder needs an API on 8443'"
---

# network-egress

`production` and `sandbox` on server1 are default-deny. This skill changes the
allowlist without turning a config edit into an outage.

Reference for what is allowed today: `docs/network-egress.md`.
Policies: `gitops/k8s-manifests/server1/network-policies/<environment>/`.

## Prerequisites

- CLIs: `kubectl`, `git`. `hubble` is **not** needed locally — it runs inside the Cilium agent pod.
- `KUBECONFIG` must hold both server1 and server3; every command names `--context`:
  ```bash
  export KUBECONFIG=iac/clusters/server1/credentials/kubeconfig:iac/clusters/server3/credentials/kubeconfig
  kubectl config get-contexts -o name     # want: admin@server1, admin@server3
  ```
- `exec ds/cilium` reaches the right agent only because server1 is a single node. On more nodes,
  exec into the agent on the node running the target pod.

## Two facts that decide everything

**1. Both environments get the same rule.** A rule written for what one environment happens to do
today is how the other ends up missing it, so `sandbox` and `production` change together. If a
second cluster ever runs apps again, its `network-policies/` must be a byte-identical copy of
server1's.

The one exception is an app deployed to one environment only (its ApplicationSet lists only
`production`, e.g. `knowledge-base-api`): its own files — `podSelector` on that app — live in that
environment's directory alone. A copy elsewhere would select nothing and suggest the app runs there.
Namespace-wide rules (`podSelector: {}`) never take this exception.

**2. A green apply proves nothing.** Cilium tracks connections in conntrack, so established
connections survive a policy change. A broken policy looks completely fine at apply time and
breaks at the next reconnect, restart or rollout — decoupled from the change that caused it.
**The restart is the test.**

## Procedure

Copy this checklist into your response and tick it off:

```
Egress change:
- [ ] 1. Drop confirmed in Hubble (or: not the policy — stop)
- [ ] 2. Right file picked
- [ ] 3. Both environments edited, reason commented, docs/network-egress.md table updated
- [ ] 4. Server-side dry-run clean for both environments
- [ ] 5. Committed + pushed; sandbox Application on the new revision
- [ ] 6. Sandbox restarted: zero drops, new flow permitted
- [ ] 7. Production synced, restarted: zero drops, new flow permitted
```

### 1. Confirm the policy is actually the cause

Do not skip to editing. Reproduce the failing call while watching:

```bash
kubectl --context admin@server1 -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace production --type drop --follow
```

`Policy denied DROPPED` with the destination you expect = confirmed. Nothing = the policy is
not your problem; stop here and say so.

### 2. Pick the right file

| Need | File |
| --- | --- |
| a non-80/443 internet port | `NetworkPolicy.egress-internet.yaml` — add to `ports` |
| a new in-cluster service | the app's `NetworkPolicy.egress-<app>.yaml` |
| a new LAN host or port | `NetworkPolicy.egress-lan-miio.yaml`, or a new file if unrelated to miIO |
| a new inbound port | `CiliumNetworkPolicy.host-ingress.yaml` |
| a whole new app | a new `NetworkPolicy.egress-<app>.yaml`, in each environment the app runs in |

Prefer **plain `NetworkPolicy`**. The one deliberate exception is `host-ingress`: all ingress
arrives from the node, and an `ipBlock` cannot match Cilium's `host` identity while
`policyCIDRMatchMode` is unset — such a rule looks correct, passes review, and matches nothing.

Scope in-cluster rules with `namespaceSelector` + `podSelector`, not IPs. Verify the selector
matches something real before trusting it:

```bash
kubectl --context admin@server1 -n <ns> get pods -l <your-selector> --show-labels
```

An empty result means the rule will silently match nothing. Fix the selector and re-run until it
lists the pods you mean.

### 3. Edit both environments

Make the change under `server1/network-policies/sandbox/` and `server1/network-policies/production/`,
then confirm they still match:

```bash
diff -r gitops/k8s-manifests/server1/network-policies/sandbox \
        gitops/k8s-manifests/server1/network-policies/production
```

The only expected differences are `namespace:` lines, comments naming the environment, and the files
of single-environment apps (fact 1). Anything else: fix it before going on.

Say **why** in a comment in the file. These files are read during incidents by someone who did
not write them; a rule whose reason is not written down gets deleted by the next person.

Update the table in `docs/network-egress.md` in the same commit. A rule the reference page does
not mention is a rule the next developer will trip over exactly as you just did.

### 4. Validate before syncing — loop until clean

```bash
for env in sandbox production; do
  kubectl --context admin@server1 apply --dry-run=server \
    -f gitops/k8s-manifests/server1/network-policies/$env/
done
```

On an error, read it, fix the file in **both** environments, and run the dry-run again. Do not
commit until both pass.

### 5. Sandbox first, then production

The Applications are **manual-sync** on purpose — `selfHeal` would undo the emergency rollback.
A push deploys nothing until you sync. After pushing, sync sandbox **once**:

```bash
kubectl --context admin@server3 -n argocd patch app network-policies-server1-sandbox \
  --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

Then confirm it took your commit, not a cached one:

```bash
kubectl --context admin@server3 -n argocd get app network-policies-server1-sandbox \
  -o jsonpath='{.status.sync.revision}{"  "}{.status.operationState.phase}{"\n"}'
git rev-parse origin/main
```

If the revisions differ, hard-refresh and sync once more — do not loop syncs:

```bash
kubectl --context admin@server3 -n argocd annotate app network-policies-server1-sandbox \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 6. Restart, and watch it come up clean — loop until zero drops

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

The Hubble ring buffer turns over in about a minute, so run these right after the rollout
finishes. **Drops present:** note each destination, go back to step 2, and repeat steps 3–6 in
sandbox. **Never move to production with a drop in sandbox.** If sandbox is broken and the fix is
not obvious, roll back (below) and stop.

When sandbox is clean, repeat steps 5–6 for `network-policies-server1-production` and namespace
`production`. A rule for a production-only app has no sandbox rehearsal: sync production, and the
restart of that app is the whole test.

For end-to-end proof that a path works rather than merely being permitted, use the
**`probe-traffic`** skill — V3 (in-pod) is the correct vantage for egress, because it inherits
the app pod's Cilium identity.

## Rollback

**Ask the operator first** — it is a `kubectl delete`, and AGENTS.md puts every delete behind a
question. Immediate, no pod restart:

```bash
kubectl --context admin@server1 -n <environment> delete networkpolicy default-deny
```

For full un-restriction also delete `allow-dns-egress` — `podSelector: {}` makes it, not
`default-deny`, the file that actually arms egress enforcement.

The rollback holds because the Application is manual-sync; the next sync re-creates whatever git
says. So the way back is a fixed commit followed by steps 4–6, not re-applying the old state by hand.

## Do not

- **Do not edit one environment only** — unless the app itself runs in one environment only (fact 1).
  The next incident will be in the other one.
- **Do not widen `allow-egress-internet` to all ports** to make a single dependency work. The
  port restriction is the remaining value in that rule; add the one port.
- **Do not use `ipBlock` for in-cluster or node traffic.** Pod IPs churn, and CIDR selectors do
  not match the `host`/`remote-node` identities on these clusters.
- **Do not enable Cilium `policyAuditMode` as a safety net.** It forwards everything, so it
  cannot detect the conntrack problem above — the failure mode that actually bites here. A
  sandbox rollout with a restart tests more, faster, and rolls back in one command.
