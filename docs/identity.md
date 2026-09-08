# Identity and authorization

Authentik is the homelab identity provider, serving `auth.irha.cz` from the server3 cluster. Every
human login to a homelab application goes through it, and every API that authorizes a caller reads a
token it minted.

The version is pinned in
[`gitops/argocd-manifests/server3/apps/identity/Authentik.yaml`](../gitops/argocd-manifests/server3/apps/identity/Authentik.yaml)
— chart version and app version are 1:1 upstream, so `targetRevision` pins both.

Design records for work that has shipped live in `docs/superpowers/specs/archive/`: the object model
in `2026-09-04-authentik-tenancy-topology.md`, the role ladder in `2026-09-08-role-hierarchy.md`. Not
every spec there is committed.

---

## The object model

| Object | What it is | What it isolates |
|--------|-----------|------------------|
| **Application** | The thing a user is granted access to. Carries the policy bindings | **The access boundary.** No binding = everyone; any binding = only who is bound |
| **Provider** | The OAuth2 client attached to an Application — `client_id`, redirect URIs, token lifetimes | Sets `aud` (always its own `client_id`) and `iss` |
| **Group** | Named collection of users and service accounts | The unit of both access and role |
| **Policy binding** | Group → Application | What actually gates |

One Application + one Provider per deployable **per environment**, one Group per role, one binding per
role group. The same binding gates `client_credentials`, so machine identities use one mechanism with
humans.

## Naming

```
Application slug / client_id :  <app>-<cluster>-<stage>     qr-manager-server1-sandbox
                                <app>-local                  qr-manager-local
Group                        :  <slug>-<role>                qr-manager-server1-sandbox-admin
Claim                        :  <app>.<role>                 qr-manager.admin
```

Authentik group names are **globally unique**, so the environment has to be in the group name to keep
the objects apart. None of it reaches the token: the `roles` mapping strips the `client_id` prefix and
re-prefixes with the application's short name, so an API sees `qr-manager.admin` in every cluster and
stage. Environment is enforced by `aud` and `iss`, checked once per request before any route reads a
role.

`{ stage: local }` is the developer-machine environment — its own `client_id`, its own issuer, its own
role groups, loopback redirect URIs. It is a full application, not a bypass, and a token it mints
reaches only an API that explicitly trusts it.

## The configuration graph

Applications, providers, groups and bindings are **not clicked together in the UI**. They are rendered
from one values matrix:

```
gitops/helm-values/server3/authentik-blueprints.yaml   ← the file you edit
  └── gitops/helm-charts/authentik-blueprints/         ← renders the blueprint
        └── ConfigMap (sync-wave -1)                   ← mounted by the Authentik worker
              └── Authentik applies it itself
```

Adding an application or a role is a few lines of values; the chart produces the repetitive YAML.

**Blueprints do not prune.** Removing an entry from values stops managing the object — it does not
delete it. A removed or renamed group keeps its members, its bindings and the access they grant until
someone deletes it in the Authentik UI.

**Memberships are not in git.** The blueprint creates groups; who is in them is UI work, by design —
user data does not belong in the repo.

## Token shape

Scope string is `openid profile email roles`. Two hand-written scope mappings replace Authentik's
shipped `profile`, which emits an unfiltered `groups` claim listing every group the user is in across
every cluster and stage.

| Claim | Value | Notes |
|-------|-------|-------|
| `aud` | `["<client_id>"]` | A one-element **array**, not the bare string Authentik defaults to. The shape must never change |
| `iss` | `https://auth.irha.cz/application/o/<client_id>/` | `issuer_mode: per_provider` — every provider signs with the same key, so `iss` is what makes a lazy verifier app-scoped rather than IdP-scoped |
| `roles` | `["qr-manager.admin", …]` | Filtered to the issuing application. Sorted |
| `sub` | username | `sub_mode: user_username` |

Access tokens live 30 minutes. **Revocation latency is bounded by that** — a demotion is not visible
until the token renews.

## Roles form a ladder

Every application declares the same three rungs:

```yaml
roles:
  - name: admin
    inherits: editor
  - name: editor
    inherits: reader
  - name: reader
```

`inherits` becomes Authentik **group parentage**, and Authentik membership flows *upward*: a member of
a child group is an effective member of its parents. So the ladder is written most-privileged first,
and `admin` is the **child** of `editor`. A user in `qr-manager-server1-sandbox-admin` and nothing else
gets:

```json
"roles": ["qr-manager.admin", "qr-manager.editor", "qr-manager.reader"]
```

The `roles` scope mapping already calls `all_groups()`, which returns the user's direct groups **plus
their ancestors**, so the parent groups simply appear in the claim.

**Why it is done in the IdP and not the API.** If `@RequireRoles('reader')` silently accepted an admin
token, the token would stop describing what its holder can do — an auditor reading it would be wrong,
and every future consumer (a second API, EMQX, a script) would need to carry the same ordering table
and agree with it. Issuing the roles correctly keeps the claim the whole truth and leaves each
consumer a plain set-membership test.

**What it buys an API.** One role as a class-level floor, narrowed per route, instead of every role
repeated on every route:

```ts
@Controller('/qr-codes')
@Authenticate(AuthMethod.Idp)
@RequireRoles('qr-manager.reader')     // floor
export class QrCodeController {
    @Get('/')       list() {}           // reader
    @Delete('/:id')
    @RequireRoles('qr-manager.admin')   // reader AND admin
    remove() {}
}
```

Ladders are **per application**: `qr-manager.admin` implies nothing about `miot-bridge`, because the
groups are per `client_id` and the mapping filters to the issuing one.

`editor` has no routes on any application yet, and `interactive-map-feeder` has no write surface at
all. The unused rungs cost a group per environment and mean the first write route on any application
is a values change rather than a re-issue of everyone's groups.

**Removing access got subtler.** Dropping someone from `-admin` leaves them whatever the parents
grant. "Remove their access" means removing the *lowest* membership they hold, not the highest.

## Applications

| Application | UI | Roles | Environments |
|-------------|-----|-------|--------------|
| `qr-manager` | `qr-manager-ui` at `apps.<cluster>…/qr-manager` | admin → editor → reader | server1 · server2 × sandbox · production, + local |
| `miot-bridge` | none — REST surface operated by hand | admin → editor → reader | server1 · server2 × sandbox · production, + local |
| `interactive-map-feeder` | none — reads of public CHMU data | admin → editor → reader | server1 · server2 × sandbox · production, + local |
| `homelab-dashboard` | `dashboard.server3.homelab.irha.cz` | admin → editor → reader | server3 production, + local |

Devices are **not** here. A device is a confidential application with `client_credentials` and a client
secret, which does not belong in git; its authorization is its `aud`, not a role claim.

## Adding an application

Edit [`gitops/helm-values/server3/authentik-blueprints.yaml`](../gitops/helm-values/server3/authentik-blueprints.yaml):

```yaml
  - name: my-app
    title: My App
    hostPrefix: apps
    basePath: /my-app          # omit if served at the host root
    roles:
      - name: admin
        inherits: editor
      - name: editor
        inherits: reader
      - name: reader
    environments:
      - { cluster: server1, stage: sandbox }
      - { cluster: server1, stage: production }
      - { stage: local }       # localPort: 5173 by default
```

Then sync `authentik-server3` in ArgoCD (Hard Refresh first — a values-only commit can read `Synced`
against a stale cache), wait ~45s for the worker to apply the blueprint, and add users to the new
groups in the UI.

The chart refuses to render an application with no roles: an Application with no policy binding is
readable by **every** user, because Authentik fails open there.

## Adding or changing a role

Add a rung to that application's `roles` list and point the rung above it at the new one. The chart:

- accepts a bare string (`- reader`) as a role with **no** parent
- emits `parents` on every role, `parents: []` included — otherwise deleting an `inherits:` line would
  leave the parentage on the instance forever
- renders parents **before** children, because `!KeyOf` resolves only against blueprint entries that
  have already been applied
- `fail`s the render on a dangling `inherits`, a self-inheriting role, a cycle (Authentik itself does
  not reject one), a duplicate role name, or a role entry with no `name`

Renaming a role is a **create plus an orphan**: the new group appears, the old one keeps its members
and its binding. Delete the old group in the UI and re-add its members.

## Operational notes

- **ArgoCD does not auto-deploy here.** Pushing is not deploying — Hard Refresh, then Sync, then wait
  for the worker.
- **Group parentage is a materialized view** (`authentik_core_groupancestry`), refreshed by a Postgres
  trigger on every parentage change. Nothing to configure, but if a claim looks stale after a
  parentage change, suspect that view rather than the mapping.
- **`AUTHENTIK_SECRET_KEY` is a first-class backup artefact.** A Postgres restore without the identical
  key yields credentials that do not decrypt. Never rotate it.
- **The bootstrap values create `akadmin` on first startup only.** Rotating them in OpenBao afterwards
  does nothing to a running install.
- **`authentik_rbac.Role` is not used at all.** That model governs who may administer Authentik itself
  and never reaches an application's token.

## Where things live

| Thing | Path |
|-------|------|
| ArgoCD Application | [`gitops/argocd-manifests/server3/apps/identity/Authentik.yaml`](../gitops/argocd-manifests/server3/apps/identity/Authentik.yaml) |
| Chart values (Authentik itself) | [`gitops/helm-values/server3/authentik.yaml`](../gitops/helm-values/server3/authentik.yaml) |
| **Application / role matrix** | [`gitops/helm-values/server3/authentik-blueprints.yaml`](../gitops/helm-values/server3/authentik-blueprints.yaml) |
| Blueprint chart | [`gitops/helm-charts/authentik-blueprints/`](../gitops/helm-charts/authentik-blueprints/) |
| Secrets + HTTPRoute | [`gitops/k8s-manifests/server3/authentik/`](../gitops/k8s-manifests/server3/authentik/) |
| OpenBao KV path | `secret/server3/authentik` — see [docs/iac.md](iac.md) step 4 |
