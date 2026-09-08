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
| `aud` | `["<client_id>"]` | A one-element **array**, not the bare string Authentik defaults to. The shape must never change. A [client-only application](#client-only-applications--one-token-several-apis) carries several entries |
| `iss` | `https://auth.irha.cz/application/o/<client_id>/` | `issuer_mode: per_provider` — every provider signs with the same key, so `iss` is what makes a lazy verifier app-scoped rather than IdP-scoped |
| `roles` | `["qr-manager.admin", …]` | Filtered to the issuing application — or, for a client-only application, to the applications it may call. Sorted |
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
| `postman` | none — a client, not an API | `user` (the access gate only) | every environment above |

Devices are **not** here. A device is a confidential application with `client_credentials` and a client
secret, which does not belong in git; its authorization is its `aud`, not a role claim.

## Client-only applications — one token, several APIs

Every application above serves an API and is addressed by its own client. `postman` is the other kind:
it serves nothing and *calls* the others. An application that declares `accesses` becomes **client-only**.

```yaml
  - name: postman
    title: Postman
    accesses: [qr-manager, miot-bridge, interactive-map-feeder, homelab-dashboard]
    redirectUris:
      - https://oauth.pstmn.io/v1/callback
    roles:
      - user
    environments: [...]
```

What the chart does with it:

- **`aud` names every API it may call**, not just itself, so one token verifies at all of them. The
  audience list is baked into a per-client copy of the `profile` mapping at render time.
- **`roles` is collected from the TARGET applications' groups.** This is the half that is easy to miss:
  the shared `roles` mapping filters on the *issuing* `client_id`, which for a client-only app would
  collect its own gate group and nothing else — a token that verifies everywhere and is authorized
  nowhere. Widening `aud` alone turns a `401` into a `403`.
- **No `refresh_token`.** Nothing here introspects; every verifier checks the signature offline, so
  expiry is the only revocation there is, and a refresh token would make a credential worth N APIs
  effectively permanent. Log in again when it expires.
- **No `meta_launch_url`, no logout URI, no host.** The callback belongs to the tool, via `redirectUris`.

**One client per environment, and that is not tidiness.** The `roles` claim is environment-free by
design — `qr-manager.admin` is the same string in every cluster and stage — so `aud` and `iss` are the
only things pinning a token to `server1-sandbox` rather than `server2-production`. A single client
spanning environments would put a sandbox admin's `qr-manager.admin` into a token the production API
accepts, with no object misconfigured. So `accesses` resolves **within one environment only**, and
each environment gets its own client:

```
postman-server1-sandbox     → qr-manager, miot-bridge, interactive-map-feeder   (that environment's)
postman-server3-production  → homelab-dashboard          (the only application server3 runs)
postman-local               → all four
```

`accesses` is the superset; each environment gets the intersection with what actually runs there. The
chart `fail`s if a target does not exist in the matrix, if a client-only app is itself someone's
target (clients are clients, APIs are APIs — this is what stops the narrow `-local` clients being
widened), if it declares a host, if it has no `redirectUris`, or if an environment resolves to no
targets at all.

**The API side needs a row per client.** `issuer_mode` is `per_provider`, so `iss` stays
`postman-<env>` however wide `aud` is: every API it addresses needs a trusted-issuer row for that
client, **for its own environment only**. That row is `iot-miniservers` config, and a
`postman-server1-sandbox` row in a production API's config re-opens exactly the escalation above.

**In Postman** it is one collection-level OAuth 2.0 config, because the authorize and token endpoints
are shared across every provider — only the `client_id` changes per environment:

| Field | Value |
|-------|-------|
| Grant type | Authorization Code (With PKCE), `S256` |
| Auth URL | `https://auth.irha.cz/application/o/authorize/` |
| Access Token URL | `https://auth.irha.cz/application/o/token/` |
| Client ID | `postman-<cluster>-<stage>` / `postman-local` — a Postman environment variable |
| Client Secret | *empty* — public client |
| Callback URL | `https://oauth.pstmn.io/v1/callback` |
| Scope | `openid profile email roles` — `roles` is **not** implied by `profile` |

The gate group `postman-<env>-user` is the only membership Postman itself needs. It grants no API
access: what the token can *do* still comes from the target applications' own role groups. It is the
switch that revokes Postman in one environment without touching anyone's application roles, and the
only revocation faster than token expiry.

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
- **A blueprint takes ~15 minutes to land, not seconds** (measured 2026-09-08). ConfigMap propagation
  into the worker's volume is ~1 min, Authentik's discovery timer is the long pole at ~10 min, and the
  import itself ran ~5 min for this matrix. The import is **one transaction**, so the objects appear
  all at once at the end — an empty query midway means "still running", not "failed". `ak
  apply_blueprint <path>` forces a run but is no faster, and it contends on row locks with the
  scheduled apply if both are in flight.
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
