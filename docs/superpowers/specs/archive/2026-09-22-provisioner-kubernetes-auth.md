# Provisioner logs in with Kubernetes auth — the actionable design

**Status:** DONE. Design implemented and documented 2026-09-22 on branch
`provisioner-kubernetes-auth` (`5a4dc6b` code, `ad6007d` docs); **step 1 applied** to OpenBao and
**verification steps 1-2 passed** — see § *How to verify*.

Merged as PR #9 (`f1e45a7`) and **verification step 3 passed on all four Applications** — all
`Synced`/`Healthy` at `f1e45a7a`, all operations `Succeeded`, every provisioner Job logging
`Skipping.`, every KV path still at `v1`.

The auto-sync warning below turned out to be half right, in an instructive way: `mongodb-server1` and
`iot-infra-server1` auto-synced within seconds because the same commit gave them a **tracked**
resource (the ServiceAccount), and ran their hooks unprompted. `emqx-server1` and `influxdb2-server1`
got only the hook change, so both read `Synced` without running anything — and `influxdb2-server1`
was still comparing against `262ff08` until a hard refresh. Both needed one explicit sync each.

**Complete 2026-09-22.** Cleanup done: both `ExternalSecret.provisioner-token.yaml` deleted
(`5db7631`), the Secrets pruned from `iot` and `mongodb`, and both retired tokens revoked by
accessor — `token-server1-provisioner` (`A5pvugEj6tEx…`) and `token-server2-provisioner`
(`6q5Pv1R7vazN…`), each of which would have expired 2026-10-08. The KV paths and the
`server2-provisioner` policy had already been removed by hand; `server1-provisioner` is kept and is
what the new role grants. `docs/architecture.md` committed in `dcdcc2d`.

**The stopgap below was never needed and is now unreachable** — there is no token left to re-mint,
and the 768h `max_lease_ttl` clamp on the token mount no longer affects anything in this system. It
is left in the document as the record of what the alternative would have been.

Written 2026-09-22. Supersedes
[`2026-09-06-provisioner-token-lifecycle.md`](2026-09-06-provisioner-token-lifecycle.md), which
diagnosed the failure (a 768h `max_lease_ttl` clamp on the token mount) and named the direction — read
it for *why*; this is *what to change*.

**Deadline.** Walking `auth/token/accessors` today: `token-server1-provisioner` and
`token-server2-provisioner`, both `orphan=true`, `period=31536000`, `creation_ttl=2764800`, both
expiring **2026-10-08T16:42Z**. `sys/auth/token/tune` → `max_lease_ttl: 2764800` (768h): **the
stopgap has not been applied**, the clamp is still in place.

**Can the real fix land first? Yes.** One cluster, one `terraform apply`, eight edited files, three
new files, two deletions — and the stored token works until 10-08, so no forced cutover, only the
fallback decision point below.

## What is true today

Measured 2026-09-22, `kubectl --context admin@<each> get ns / externalsecret -A / jobs -A`:

| | server1 | server2 | server3 |
|---|---|---|---|
| `iot` / `mongodb` namespaces | both present | **neither** (has `ollama`) | neither |
| `openbao-provision-token` ExternalSecrets | `iot`, `mongodb` | none | none |

**Scope is server1 only.** server2's IoT estate went in `1ef7e32` *chore(server2): drop the orphaned
IoT values, manifests and Traefik ports*, deleting both server2 `ExternalSecret.provisioner-token.yaml`
files and `gitops/helm-values/server2/provisioner/` — the old spec's "all four" is now **two**. Zero
Jobs anywhere is expected, not a symptom: `hook-delete-policy: HookSucceeded,BeforeHookCreation`
removes each Job as it succeeds.

**No provisioner is a deletion candidate — all three migrate.** `get statefulset -n iot -n mongodb`
on server1: `emqx 1/1`, `influxdb2 1/1`, `mongodb 1/1`. The chart is a fourth `sources` entry on
`apps/iot/EMQX.yaml`, `apps/iot/InfluxDB2.yaml` (→ ns `iot`) and `apps/databases/MongoDB.yaml`
(→ ns `mongodb`), each with a single-element list generator, `cluster: server1`.

**The Job shape** is identical in all three templates, e.g.
[`templates/mongodb/job.yaml`](../../../../gitops/helm-charts/provisioner/templates/mongodb/job.yaml)
lines 22-37: `automountServiceAccountToken: false`, **no** `serviceAccountName`, and a `BAO_TOKEN`
env entry from `secretKeyRef` → `{{ $.Values.global.baoTokenSecret }}` key `token`. `baoPrelude` in
[`_helpers.tpl`](../../../../gitops/helm-charts/provisioner/templates/_helpers.tpl) then runs
`bao token lookup` and aborts before touching a datastore. That guard stays.

**ESO's Kubernetes auth was created by hand, not by Terraform.** `iac/modules/vault-config/` holds
`oidc.tf` only (`vault_jwt_auth_backend{,_role}`, `vault_policy.oidc`, `vault_identity_group{,_alias}`);
no `vault_auth_backend` of type `kubernetes` and no `vault_kubernetes_auth_backend_role` exists
anywhere under `iac/`. `iac/clusters/server3/vault-config/main.tf` says so — *"Anything added later
that must exist BEFORE ArgoCD (ESO's Kubernetes auth, for example) needs its own toggle or its own
stage."* Runbook: `docs/quickstart.md:231-246`, `docs/iac.md:235-259`. **CLI work, not Terraform.**

**OpenBao state.** `bao auth list` → `kubernetes-server1/2/3`, `oidc/`, `token/`, `userpass/`;
`bao list auth/kubernetes-server1/role` → `["external-secrets"]`, same on the other two, so **no
`provisioner` role exists on any mount**. `bao policy read server1-provisioner` exists and is correct
(`create/read/update/patch` on `secret/data/server1/*`, `read/list` on `secret/metadata/server1/*`).
The role to copy, `auth/kubernetes-server1/role/external-secrets`: `bound_service_account_names` and
`bound_service_account_namespaces` both `[external-secrets]`, `policies=[server1-external-secrets]`,
`token_ttl=3600`, mount config `kubernetes_host: https://192.168.1.200:6443` — which answers the old
spec's cross-cluster question: each mount validates only its own cluster's API server.

**`automountServiceAccountToken: false` is deliberate, repo-wide policy — and the repo already has
the pattern that replaces it.** The provisioner chart's own history explains nothing (`39f1c4e`,
2026-04-25, a 14-file bulk commit whose entire message is `provisioning`), but the convention is
stated in five places outside it:

- [`docs/architecture.md:153`](../../../architecture.md) — *"All ServiceAccounts have
  `automountServiceAccountToken: false` — tokens are not auto-mounted. When API-to-API communication
  is enabled, projected tokens will be mounted on-demand via the Deployment spec."*
- `c43b555` *feat(chart): opt-in projected ServiceAccount token and CA bundle* (2026-08-28) — *"Opt-in
  via `serviceAccount.projectedToken.enabled`, default off, and automountServiceAccountToken stays
  false. The point is an explicit, scoped, short-lived token rather than an ambient full-audience
  one."* The same commit gave `qr-manager-ui` its own SA because it "was the one pod in these
  namespaces still holding an ambient cluster token."
- [`iot-applications/_helpers.tpl:173`](../../../../gitops/helm-charts/iot-applications/templates/_helpers.tpl)
  — *"Kept opt-in… this volume is explicit, scoped and short-lived, which is the point. A workload
  that never calls the apiserver gets nothing."*
- `7aa5b7d` *docs(netpol)* — the CA comes from the `kube-root-ca.crt` ConfigMap *"so
  `automountServiceAccountToken: false` stays as it is"*.
- [`docs/provisioning.md:26`](../../../provisioning.md) — the provisioner-specific reason: *"makes no
  K8s API calls."*

So it is load-bearing, it needs no user decision, and it does **not** have to be flipped: a projected
volume delivers the token without it. The provisioner's case is simpler than the APIs' — the pod
never calls the apiserver, it only hands the JWT to OpenBao, which does the TokenReview itself
(`auth/kubernetes-server1/config` → `token_reviewer_jwt_set: true`, measured 2026-09-22). No `ca.crt`,
no apiserver egress, no audience to get wrong.

## Design

**1. One OpenBao role, in Terraform**, reusing the policy that already exists. `token_ttl=3600`
mirrors ESO's; a Job runs in seconds, so nothing renews and nothing needs to.

It goes in `iac/modules/vault-config/`, answering half of the second open question below. The role
has neither problem that keeps the *mount* on the CLI: PostSync hooks run long after this stage, and
a role stores no secret. `backend` takes a plain string, so it names the CLI-created mount with no
cross-stage dependency.

```hcl
# iac/clusters/server3/vault-config/main.tf
kubernetes_provisioner_roles = {
  "kubernetes-server1" = {
    namespaces     = ["iot", "mongodb"]
    token_policies = ["server1-provisioner"]
  }
}
```

`terraform plan` against live OpenBao, 2026-09-22: **1 to add, 0 to change, 0 to destroy** — the
OIDC resources show no drift.

**2. The ServiceAccount is a raw manifest, not a chart template.** `emqx-server1` and
`influxdb2-server1` both render the chart into `iot`, so a chart-owned SA would be one object claimed
by two Applications — a SharedResourceWarning and a permanent OutOfSync flap.
`gitops/k8s-manifests/server1/iot/` also holds *only* `ExternalSecret.provisioner-token.yaml`, so
deleting that leaves `IotInfra` pointing at a path git cannot represent. The SA takes its place:
same directory, same sync-wave `"0"` as the ExternalSecret it replaces. Wave is not load-bearing
either way — a PostSync hook runs after every wave — but `iot` is a cross-Application dependency
worth naming: the SA is synced by `IotInfra` while the Jobs come from `EMQX` and `InfluxDB2`. That is
exactly how the token ExternalSecret already worked, so it is not a new failure class. In `mongodb`
both live in the same Application.

**3. The Job gets an identity and logs in:** `serviceAccountName: provisioner`,
`automountServiceAccountToken` left at `false`, a projected token volume at the conventional path,
the `BAO_TOKEN` env block deleted, and `baoPrelude` opening with the login below — the mount name derives from `global.cluster`, so no new value, and it matches
ESO's. Nothing blocks it at the network layer: `get networkpolicy,ciliumnetworkpolicy -A` on server1
shows policies only in `longhorn-system`, `production`, `sandbox`, plus one Bitnami policy selecting
`app.kubernetes.io/instance=mongodb` — none selects a provisioner pod, and `auth/*` is the same host
and port as today's KV traffic. The `bao token lookup` guard stays immediately after the login: that
login can succeed and still carry the wrong policy, which must not reach a datastore either.

The volume follows `iot-applications.projectedToken.volume`, minus the `ca.crt` source and the
audience list — neither is reachable from, or useful to, a pod that only talks to OpenBao:

```yaml
# provisioner.jobSpec
automountServiceAccountToken: false        # unchanged; the volume below is the explicit grant
volumes:
  - name: bao-login-token
    projected:
      defaultMode: 420
      sources:
        - serviceAccountToken:
            path: token
            expirationSeconds: 600         # a Job runs in seconds; ESO's 3600 is generous here
# container
volumeMounts:
  - name: bao-login-token
    mountPath: /var/run/secrets/kubernetes.io/serviceaccount
    readOnly: true
```

```sh
BAO_TOKEN=$(bao write -address="${BAO_HOST}" -field=token \
  "auth/kubernetes-${CLUSTER}/login" role=provisioner \
  jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token) || {
  echo "ERROR: Kubernetes auth login to ${BAO_HOST} failed — refusing to touch any datastore."
  exit 1
}
export BAO_TOKEN
```

**4. OpenBao's seal state becomes a sync-time dependency, but not a new failure class.** OpenBao
reseals on reboot and needs three unseal keys by hand. Today a sealed OpenBao fails
`bao token lookup`; afterwards it fails the login one line earlier — both abort before any datastore
call. So the unchanged rule belongs in `docs/provisioning.md`: **do not sync a datastore Application
while OpenBao is sealed** — and step 1 needs an unsealed OpenBao and an admin session.

## What changes, file by file

| File | Change |
|---|---|
| `helm-charts/provisioner/templates/_helpers.tpl` | `baoPrelude` gains the login ahead of the existing `bao token lookup` guard; `provisioner.jobSpec` (until now defined but unused) gains `serviceAccountName` and the projected volume and is now actually included; new `provisioner.baoLoginVolume{Name,Mount}` |
| `.../templates/{emqx,influxdb2,mongodb}/job.yaml` | drop the `BAO_TOKEN` env entry; add `serviceAccountName: {{ $.Values.global.serviceAccountName \| default "provisioner" }}`, the projected `bao-login-token` volume and its mount. `automountServiceAccountToken: false` in `provisioner.jobSpec` stays |
| `helm-charts/provisioner/values.yaml` + `helm-values/server1/provisioner/{emqx,influxdb2,mongodb}.yaml` | drop `global.baoTokenSecret` from the chart defaults and from each `global:` block; add `global.serviceAccountName: provisioner` |
| **new** `k8s-manifests/server1/{iot,mongodb}/ServiceAccount.provisioner.yaml` | SA `provisioner`, one per provisioner namespace |
| **delete** `k8s-manifests/server1/{iot,mongodb}/ExternalSecret.provisioner-token.yaml` | the last two of the old spec's "four" |
| **new** `iac/modules/vault-config/kubernetes.tf` | `vault_kubernetes_auth_backend_role.provisioner`, `for_each` over mount paths; header records why the mount and ESO's role stay on the CLI |
| `iac/modules/vault-config/variables.tf` | `kubernetes_provisioner_roles` (map keyed by mount path) + `kubernetes_provisioner_role_name` |
| `iac/clusters/server3/vault-config/main.tf` | declare the `kubernetes-server1` entry; correct the stale header comment that said ESO's mount must exist "BEFORE ArgoCD" |
| `docs/provisioning.md` | rewrite § *Shared provisioner token (IotInfra)* (94-124) and the `403 permission denied` runbook (350-390); checklist item 4 no longer applies |
| `docs/quickstart.md:231-267`, `docs/iac.md:250-285` | delete the `bao token create -orphan` + `bao kv put .../provisioner-token` blocks; point at the `vault-config` stage instead |
| `gitops/README.md:166`, `docs/architecture.md:38`, `AGENTS.md:218,224` | drop `provisioner-token` from the seed list and the inventories; `iot-infra` now carries the SA |

**Dead weight the same change clears from OpenBao.** server2 has had no consumer since `1ef7e32`:
revoke `token-server2-provisioner` by accessor, `bao kv metadata delete secret/server2/provisioner-token`,
`bao policy delete server2-provisioner`; then the server1 pair once the new path is proven. Keep the
`server1-provisioner` **policy** — the new role uses it unchanged.

## How to verify, without wedging an Application

ArgoCD is last, not first: re-triggering a sync kills in-flight PostSync Jobs and `Synced` never
covers a hook, so each stage below proves itself on its own.

1. **Login only, no chart.** Create the SA, then a throwaway pod on it (`kubectl -n iot run
   bao-login-check --rm -it --restart=Never --image=<the digest in values.yaml> --overrides=
   '{"spec":{"serviceAccountName":"provisioner","volumes":[{"name":"bao-login-token","projected":
   {"sources":[{"serviceAccountToken":{"path":"token","expirationSeconds":600}}]}}],"containers":
   [{"name":"c","image":"<digest>","command":["sh"],"stdin":true,"tty":true,"volumeMounts":
   [{"name":"bao-login-token","mountPath":"/var/run/secrets/kubernetes.io/serviceaccount"}]}]}}'`);
   run the login, `bao token lookup` it — `policies` must contain `server1-provisioner`, `ttl` ≈ 3600.
   This also proves the projected volume alone is enough, with automount still off.

   **Passed 2026-09-22, from both `iot` and `mongodb`.** The mount directory holds `token` and
   nothing else — no `ca.crt`, no `namespace`. `policies: ["default", "server1-provisioner"]`,
   `ttl: 3600`, `display_name: kubernetes-server1-<ns>-provisioner`,
   `meta.service_account_namespace` matching the pod. `bao write -field=token` does resolve to
   `auth.client_token` on a login response. Scope holds in both directions: reading
   `secret/server1/production/qr-manager-api-mongodb` succeeds, `secret/server2/mongodb` is denied.
2. **The real Job, by hand.** `helm template` the chart with
   `helm-values/server1/provisioner/mongodb.yaml`, strip the `argocd.argoproj.io/*` annotations,
   rename the Job, apply it in `mongodb`. Every entry must log `already in OpenBao. Skipping.` — the
   credentials exist, so a correct run writes nothing; prove it with `bao kv metadata get
   secret/server1/production/qr-manager-api-mongodb` (`current_version` unchanged). Delete the Job.

   **Pass `-n mongodb` on the apply.** The chart's Job templates carry no `metadata.namespace` —
   correct for Helm, where the release supplies it — so hand-applied `helm template` output lands in
   the context's default namespace instead. It fails safe if you forget (`error looking up service
   account default/provisioner`: no pod is ever created, nothing is touched), but it looks like the
   Job vanished.

   **Passed 2026-09-22.** All four mongodb Jobs `Complete` in 5s, each logging
   `already in OpenBao. Skipping.`; all four KV paths still at `v1`.
3. **One ArgoCD sync, once.** ⚠️ **All four Applications run `automated: {selfHeal, prune}`**
   (`apps/iot/{InfluxDB2,EMQX,IotInfra}.yaml`, `apps/databases/MongoDB.yaml`), so pushing the commit
   fires all three datastore syncs on the next reconciliation, unattended and in parallel — the
   opposite of what this step asks for. Either accept that (the Jobs are idempotent, the prelude
   aborts before any datastore call, and verification step 2 has already exercised the real Job
   against the real OpenBao), or disable automation **bootstrap → root → leaf** before pushing: a
   patch on the child alone is restored by the parent's selfHeal in ~90s. Sync
   `influxdb2-server1` — the smallest of the three — and let it
   finish. Start `kubectl logs -f job/influxdb2-provision-loxone -n iot` immediately; `HookSucceeded`
   deletes the Job and takes its logs with it. **Do not re-sync**: on a `Failed` operation phase read
   `.status.operationState` instead. Then `emqx-server1`, then `mongodb-server1`, one at a time.
4. Only once all three are green: revoke the tokens and delete the KV paths listed above.

## Decision point on the stopgap

**If step 3 has not passed on all three Applications by 2026-10-01**, stop and apply the stopgap,
then resume without deadline pressure. Confirm afterwards that the new accessor's `expire_time` is a
year out rather than 32 days — that check *is* the stopgap. server2 needs no replacement token.

```sh
bao auth tune -max-lease-ttl=8760h token/
TOKEN=$(bao token create -policy=server1-provisioner -period=8760h -orphan \
  -display-name="server1-provisioner" -field=token)
bao kv patch secret/server1/provisioner-token token="${TOKEN}"   # patch, never put
unset TOKEN
```

## Out of scope

- Rotating the credentials the provisioner **writes** (`docs/secrets.md`), and the `server1-provisioner` policy — measured correct above.
- `bao_write` in `_helpers.tpl` uses `bao kv put`, which replaces a whole path. Every caller guards it
  with an existing-credential check, so not a live bug — but the kind that becomes one. Separate change.
- `provisioner` roles on `kubernetes-server2` / `kubernetes-server3`: no consumers exist. Likewise
  server2's orphaned KV tree (`secret/server2/` still holds `emqx`, `influxdb2`, `mongodb`,
  `telegraf-*`, `production/`, `sandbox/`) — a broader cleanup, not this one.
- MinIO, Longhorn backups, a renewal CronJob — all rejected before, and Kubernetes auth makes the
  third unnecessary anyway.

## Open questions

*(The `automountServiceAccountToken` question is closed — see § What is true today. It is deliberate,
it stays `false`, and a projected volume replaces it.)*

- **Should the Kubernetes auth mounts and roles move into `iac/modules/vault-config/`?** They are the
  only OpenBao objects still created by CLI. Resources exist in the module's pinned provider
  (vault 5.11.0): `vault_auth_backend`, `vault_kubernetes_auth_backend_config`,
  `vault_kubernetes_auth_backend_role`, `vault_policy`. Two things keep the **mount** out:

  1. *Ordering.* Not "before ArgoCD" — ArgoCD needs no ESO, because Terraform reads OpenBao directly
     and writes `argocd-secret` itself ([`modules/apps/argocd.tf:21`](../../../../iac/modules/apps/argocd.tf),
     with `configs.secret.createSecret: false`). The real line is **before the first ArgoCD app sync
     carrying an ExternalSecret**. `vault-config` runs after `authentik-server3` is Healthy, and
     authentik has two ExternalSecrets — so ESO must already work before this stage can run at all.
     Putting ESO's mount here is circular. `main.tf`'s own comment names the need for its own stage.
  2. *State.* `token_reviewer_jwt` is a non-expiring `system:auth-delegator` credential and vault 5.x
     has no write-only variant for it, so it would land in plaintext `terraform.tfstate` (gitignored,
     `.gitignore:4`, but local and unencrypted). The OIDC secret was deliberately kept out of state
     with `_wo`; this would be a step back from that.

  The **provisioner role has neither problem**: PostSync hooks run long after everything above, the
  role holds no secret, and `vault_kubernetes_auth_backend_role.backend` takes a plain string, so it
  can reference the CLI-made `kubernetes-server1` mount with no cross-stage dependency. It also does
  not exist yet, so no `terraform import`. **Done** — `kubernetes.tf` holds the provisioner role and
  is step 1 of the design above. Mount, config and the ESO roles stay on the CLI until someone writes
  a pre-GitOps stage; that remains open.
