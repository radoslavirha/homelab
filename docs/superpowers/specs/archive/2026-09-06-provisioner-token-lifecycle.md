# Provisioner credentials — stop minting long-lived tokens by hand

**Status:** RESOLVED 2026-09-22, superseded by
[`2026-09-22-provisioner-kubernetes-auth.md`](2026-09-22-provisioner-kubernetes-auth.md) — which
this document's diagnosis pointed at and which is now shipped (`f1e45a7`). The provisioner Jobs log
in with Kubernetes auth; both hand-minted tokens have been revoked and their KV paths deleted, so
the 2026-10-08 expiry named below never arrived. Kept for the diagnosis: the 768h `max_lease_ttl`
clamp, and why `-period` alone does not survive it.

The original text follows unchanged.

**Status when written:** open. Nothing is broken right now — the tokens were re-minted on 2026-09-06
and every provisioner Job succeeds. This is about the fact that they will break again, on a date we
can already name.

**Trigger:** a real outage on 2026-09-06. All eight `mongodb-provision-*` PostSync Jobs on server1
and server2 were in `CrashLoopBackOff` with

```
ERROR: OpenBao token invalid/expired or https://vault.server3.homelab.irha.cz unreachable
       — refusing to touch any datastore.
```

**Related:** credential rotation — of the credentials the provisioner *writes* (its old plan no longer
exists; `docs/secrets.md` is the current reference). This spec is the layer underneath: the
credential the provisioner uses to write them at all.

---

## What is true today

```
human runs `bao token create` once
   └─▶ secret/<cluster>/provisioner-token   (KV v2, a token stored as data)
         └─▶ ESO ClusterSecretStore `openbao`
               └─▶ Secret openbao-provision-token   in ns `iot` AND ns `mongodb`
                     └─▶ env BAO_TOKEN in every provisioner Job
```

- One token per cluster, shared by both namespaces (verified: identical SHA-256 within a cluster,
  different across clusters). server3 has no provisioner token.
- The Jobs run with `automountServiceAccountToken: false` and **no** `serviceAccountName`
  ([`provisioner/templates/mongodb/job.yaml`](../../../../gitops/helm-charts/provisioner/templates/mongodb/job.yaml)).
  They have no Kubernetes identity at all, which is *why* a stored token is needed.
- `provisioner.baoPrelude` runs `bao token lookup` before touching any datastore, so a dead token
  fails cleanly instead of stranding a rotated password. **That safety net worked** — nothing was
  corrupted in the incident.

## Why it broke, and why it will break again

**The one-year period is silently clamped to 32 days.** Measured on a freshly minted token:

```
period      = 31536000   (1 year, as requested on the CLI)
ttl         =  2764553
expire_time = 2026-10-08
```

`2,764,800 s` is **exactly 768h**, OpenBao's default `max_lease_ttl`. Nothing renews the token, so
it dies ~32 days after minting regardless of the `-period` argument. The previous token was roughly
4½ months old — far past 32 days, nowhere near a year — which fits this and does not fit the
`-orphan` explanation the troubleshooting docs give.

So there are **three** independent failure modes stacked on one manual step:

1. **TTL clamp** — `-period=8760h` is not honoured while the token auth mount's `max_lease_ttl`
   is 768h. Nothing warns you; `bao token create` succeeds and reports the period you asked for.
2. **Orphan-ness** — a non-`-orphan` token is revoked with the login token that minted it. Two of
   the four `ExternalSecret.provisioner-token.yaml` setup blocks still omit `-orphan`, and those
   are the ones a human copy-pastes.
3. **Silence** — Jobs only run on an ArgoCD sync, so a dead token is invisible until the next sync,
   which may be months later. ArgoCD reports `Synced`/`Healthy` throughout; only the PostSync
   operation phase goes `Failed`.

A dead token is also **not self-healing**: the Jobs exhaust `backoffLimit: 6` and stop. A Hard
Refresh does not revive them — only a Sync does, via `BeforeHookCreation`.

## Proposed direction — no stored token at all

**ESO already solves this exact problem on the same OpenBao, and the provisioner should copy it.**
Each cluster has a dedicated Kubernetes auth mount (`kubernetes-server1`, `kubernetes-server2`,
`kubernetes-server3`) with role `external-secrets` bound to a ServiceAccount
([`ClusterSecretStore.yaml`](../../../../gitops/k8s-manifests/server2/external-secrets/ClusterSecretStore.yaml)).
No token is stored anywhere and nothing expires.

The provisioner Jobs would log in at run time instead:

```sh
BAO_TOKEN=$(bao write -field=token \
  auth/kubernetes-${CLUSTER}/login \
  role=provisioner \
  jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)
```

What has to change:

- A `ServiceAccount` in the provisioner chart, `automountServiceAccountToken: true` on the Job.
  (Both are currently absent, deliberately — revisit whether the original reason still holds.)
- An OpenBao Kubernetes auth **role** `provisioner` per cluster mount, bound to that SA in
  namespaces `iot` and `mongodb`, carrying the existing `<cluster>-provisioner` policy. The policy
  itself is already correct and needs no change.
- `baoPrelude` gains the login; `BAO_TOKEN` stops being an env var sourced from a Secret.
- Delete all four `ExternalSecret.provisioner-token.yaml`, the `openbao-provision-token` Secrets,
  and the `secret/<cluster>/provisioner-token` KV paths.

**What this buys:** the token is minted per Job run, lives minutes, and is scoped to a Kubernetes
identity rather than a string someone pasted. Failure modes 1 and 2 disappear entirely. No manual
step survives, so there is nothing to forget.

## Alternatives considered

| Option | Verdict |
|---|---|
| Raise the token mount's `max_lease_ttl` to `8760h`, re-mint | **Do this anyway as the stopgap** — it is one UI change and buys a year. Does not remove the manual step or the silence |
| Periodic renewal CronJob | Adds a component whose own failure is equally silent. Renewing a token to avoid expiry is work the Kubernetes auth method does for free |
| Mint via the `hashicorp/vault` Terraform provider | Puts a live token in Terraform state, which is worse than where it is now. Also couples credential lifecycle to `terraform apply` |
| Leave it, document the expiry | Rejected: the failure is silent for months and the docs that describe the fix already disagree with each other |

## Open questions for whoever picks this up

- **Why is `automountServiceAccountToken: false` set today?** It may be deliberate hardening. If so,
  weigh it against the stored long-lived token it forces — a mounted SA token scoped to one role is
  the smaller exposure, but confirm rather than assume.
- **Does the OpenBao Kubernetes auth mount validate tokens from the *other* clusters?** ESO proves
  the per-cluster mounts work from server1/server2, so this should be a non-issue; verify.
- **EMQX and InfluxDB2 provisioners use the same token** and must migrate in the same change, or
  the `iot`-namespace Secret cannot be deleted.
- **Is a Kubernetes auth login reachable from the Jobs' network position?** They already reach
  `https://vault.server3.homelab.irha.cz` for KV, so the same endpoint serves `auth/*`. Confirm no
  NetworkPolicy distinguishes the paths.

## Non-goals

- Rotating the credentials the provisioner writes — that is the credential-rotation plan.
- Changing the `<cluster>-provisioner` policies. They are correct as they stand
  (`create/read/update/patch` on `secret/data/<cluster>/*`, `read/list` on
  `secret/metadata/<cluster>/*`).

## Immediate stopgap, independent of this spec

Set the token auth mount's **Maximum Lease TTL to `8760h`** and re-mint both tokens, then confirm
`expire_time` lands a year out rather than 32 days. Without that, the next failure is
**2026-10-08**.
