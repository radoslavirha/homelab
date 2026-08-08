# Validator `runAsUser` — Follow-up After the Numeric-UID Fix

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Repo:** `/Users/radoslavirha/dev/irha/homelab`.

**Size:** one comment, in two chart templates. Optionally one line of values. No functional change.

**Origin:** the `CreateContainerConfigError` that blocked the first `validate: true` sync has been fixed **in the images**, in `iot-miniservers` (commit `c286c71`). This is the resulting doc drift on the chart side.

> **Done — 2026-08-08.** Released as `qr-manager-ui@0.7.1` / `homelab-dashboard-ui@0.4.1`, both images confirmed `.Config.User = 1000`, all five environments rolled to the new tags with `0` restarts and both validators `Completed exit=0`. The scratch-pod check ran: `runAsNonRoot: true` with **no** `runAsUser` starts and reports `running as uid 1000`. Comments in `deployment.yaml`, `rollout.yaml` and `values.yaml` now describe `runAsUser` as a defensive default; the value itself was left in place.

**Related:**

| Doc | Repo | Relationship |
| --- | --- | --- |
| `docs/superpowers/plans/2026-08-07-iot-applications-template-validation.md` | this repo | Owns the chart feature. Its decision 4a and the `runAsUser` comment are what go stale |
| `docs/superpowers/specs/2026-08-08-nginx-ipv6-listener.md` | `iot-miniservers` | The other half of that round. **Needs nothing here** — see below |

---

## What changed upstream

Both validator images now declare a numeric UID:

```dockerfile
USER 1000     # was: USER node
```

Verified in `iot-miniservers` before release: `.Config.User` is `1000`, `id` inside reports `uid=1000(node)`, the validator still exits 0, and it runs under `docker run --read-only` so `readOnlyRootFilesystem` stays satisfiable.

The kubelet can now verify `runAsNonRoot: true` from the image alone, because it can read a numeric UID out of the image config — it never could resolve the name `node`, since that mapping lives in the image's `/etc/passwd`.

## What is now wrong here

`templates/deployment.yaml:130` and `templates/rollout.yaml:121` carry:

```gotemplate
{{- /* runAsUser is REQUIRED, not belt-and-braces: the validator images declare
       a non-numeric user ... with runAsNonRoot alone it refuses to start
       the container with CreateContainerConfigError ... */}}
runAsUser: {{ ... | default 1000 }}
```

The **value stays correct**. The **justification inverts**: once the fixed images are deployed, `runAsUser` is a defensive default, not a requirement. Left as written, the next reader concludes the images are still broken and may go re-fix something that is already fixed.

---

## ⚠️ Sequencing — gate satisfied, applied 2026-08-08

The fix is committed but **not released**. The images currently running in-cluster —
`qr-manager-ui-config-validator:0.7.0` and `homelab-dashboard-ui-config-validator:0.4.0` — **still have `USER node`**, so the comment is accurate *today* and `runAsUser` is genuinely load-bearing.

- [x] Wait for the `iot-miniservers` release, then for the deploy action to bump `image.tag` in `gitops/helm-values/apps/qr-manager-ui/*.yaml` and `gitops/helm-values/server3/homelab-dashboard-ui.yaml`.
- [x] Confirm the bumped tag actually has the numeric UID before touching anything:
      `docker image inspect ghcr.io/radoslavirha/qr-manager-ui-config-validator:<new tag> --format '{{.Config.User}}'` → `1000`.
- [x] **Never remove `runAsUser` in the same window as the tag bump.** If anything goes wrong you would be debugging two variables. The value is harmless; only the comment needs to change.

---

## Steps

- [x] `templates/deployment.yaml` — rewrite the comment above `runAsUser` to say it is a defensive default: the validator images declare `USER 1000` themselves and satisfy `runAsNonRoot` unaided, but the chart cannot verify what an arbitrary `validate.repository` override contains, so it keeps supplying a known-good UID.
- [x] `templates/rollout.yaml` — identical change, as the two templates are kept in step.
- [x] `values.yaml` — if the `validate` block documents `runAsUser`, make the same correction there.
- [x] `docs/superpowers/plans/2026-08-07-iot-applications-template-validation.md` — decision 4a's table says the image satisfies `runAsNonRoot` "without a chart-supplied `runAsUser`". That was aspirational when written and is now true; mark it as verified rather than intended, and note which image version made it true.

## Verification

- [x] `helm unittest gitops/helm-charts/iot-applications` — unchanged, since only comments move.
- [x] Once deployed, a **scratch** `helm template` with `runAsUser` removed renders a validator that still starts, confirming the image satisfies `runAsNonRoot` on its own. This is a check, **not a change** — do not commit that removal.

---

## The IPv6 work needs nothing here

The other spec in that round (`iot-miniservers` — `specs/2026-08-08-nginx-ipv6-listener.md`) adds an IPv6 listener to the two nginx UIs. Recorded here so it is not re-derived:

- Probe values use `httpGet` against the pod IP; the chart never names an address family. No values change.
- The only `localhost`-based checks in this repo's plans target `api-iot-qr-manager-api`. That is a Node server, and Node's `listen(port)` with no host binds `::` — dual-stack, accepting IPv4 too. Verified. So those commands work and keep working.
- nginx is the opposite: an explicit `listen 80;` is IPv4-only. That asymmetry is why the defect exists only in the UIs, and why nothing about the APIs or the chart needs to change.

The one thing worth knowing operationally: if these clusters ever go **dual-stack**, the kubelet would probe the pod IP of the new family, and the UIs would fail liveness until that spec ships. Not urgent today; relevant if anyone plans an IPv6 rollout.
