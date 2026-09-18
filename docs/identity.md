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
| `qr-manager` | `qr-manager-ui` at `apps.<cluster>…/qr-manager` | admin → editor → reader | server1 × sandbox · production, + local |
| `miot-bridge` | none — REST surface operated by hand | admin → editor → reader | server1 × sandbox · production, + local |
| `interactive-map-feeder` | none — reads of public CHMU data | admin → editor → reader | server1 × sandbox · production, + local |
| `homelab-dashboard` | `dashboard.server3.homelab.irha.cz` | admin → editor → reader | server3 production, + local |
| `argocd` | `argocd.server3.homelab.irha.cz` | admin → editor → reader | server3 production |
| `grafana` | `grafana.irha.cz` | admin → editor → reader | server3 production |
| `headlamp` | `headlamp.<cluster>.homelab.irha.cz` — the token goes to **kube-apiserver**, see [Headlamp](#headlamp) | admin → editor → reader, bound to `cluster-admin` / `edit` / `view` | server1 · server2 · server3, production |
| `openbao` | `vault.server3.homelab.irha.cz` — **confidential**, see [OpenBao](#openbao) | admin → editor → reader | server3 production |
| `mealie` | `mealie.irha.cz` — **confidential**, see [Mealie](#mealie) | `admin` → `user` — **two rungs**, because Mealie has only `OIDC_ADMIN_GROUP` and `OIDC_USER_GROUP` | server1 production |
| `postman` | none — a client, not an API | `user` (the access gate only) | one client, every environment |
| `interactive-map` | none — an ESP32, `kind: device` | none of its own; holds `interactive-map-feeder.reader` | one client: server1 production + local |
| `longhorn` | `longhorn.<cluster>.homelab.irha.cz` — **`kind: proxy`**, see [Proxies](#proxies--uis-with-no-login-of-their-own) | `admin` (the access gate only) | server1 · server2 · server3, production |
| `hubble` | `hubble.<cluster>.homelab.irha.cz` — **`kind: proxy`**, the Cilium flow UI in `kube-system` | `admin` (the access gate only) | server1 · server2 · server3, production |
| `traefik` | `traefik.<cluster>.homelab.irha.cz` — **`kind: proxy`**, and the one guarded by an **IngressRoute** rather than an HTTPRoute | `admin` (the access gate only) | server1 · server2 · server3, production |

## `kind` — what sort of client an entry is

`kind` is **ours**, not Authentik's `client_type` (public/confidential), which is derived from it.

| | `api` (default) | `client` | `device` | `proxy` |
|---|---|---|---|---|
| Who drives it | a human's browser | a human | a machine | a human's browser |
| Authentik `client_type` | public — or confidential with `confidential: true` | public | **confidential** | confidential — **Authentik's choice, not ours** |
| Grants | code + refresh | code | **client_credentials** | code + client_credentials + password, **all forced by Authentik** |
| Redirect URIs | derived from the host | `redirectUris` | **none** | **derived by Authentik** from `external_host` |
| Roles claim from | its own groups | the human's groups at the target | **the role named in `accesses`** | **nothing — no token ever reaches the app** |
| Environments | one Application each | **one client, spanning all** | **one client, spanning all** | one Application each |

The difference between `client` and `device` is *whose* groups fill the roles claim. A `client`
borrows the human's, so it names bare applications. A `device` has no human, so each access names the
role and the chart puts the device's service account in that group:

```yaml
accesses: [qr-manager]                          # client
accesses: [{ app: qr-manager, role: reader }]   # device
```

### Devices

A device is a machine identity: no browser, no redirect, no password prompt. It presents a `client_id`
and a `client_secret` to the token endpoint and gets a signed JWT, verified against the same JWKS as
every human token.

```yaml
  - name: interactive-map
    title: Interactive Map (LaskaKit ESP32)
    kind: device
    accesses:
      - { app: interactive-map-feeder, role: reader }
    environments:
      - { cluster: server1, stage: production }
      - { stage: local }
```

**Several environments means one client, not one per environment.** `interactive-map` renders a single
confidential client whose `aud` names `interactive-map-feeder-server1-production` and
`interactive-map-feeder-local`, with one secret to flash and one service account — placed in the
`reader` group of both environments.

**The service account is declared, not left to Authentik.** The `client_credentials` grant does
`update_or_create()` on a username it derives — `ak-<provider name>-client_credentials` — and creates
it **in no groups**. Left alone, the first token request would produce an empty `roles` claim and then
be refused by the application's bindings, *after* creating the user. The chart emits that user ahead of
time, in the target's role group; `update_or_create` then finds it by username and overwrites only
name/path/type, so the membership survives. Get the username wrong by one character and Authentik
silently creates a second, group-less user beside it.

Verified on 2026-09-09 with a real `client_credentials` request: `sub` came back as
`ak-interactive-map-client_credentials` — the declared username — with
`roles: ["interactive-map-feeder.reader"]` and a three-entry `aud`. A non-empty roles claim is the
proof that the declared account was used rather than a fresh group-less one.

**Two fields are required even though they look inapplicable, and omitting either fails the WHOLE
blueprint** — no entry applies, `BlueprintInstance.status` reads `error`, and the task log still says
*"Task finished processing without errors"*. Look at the instance, not the task. A device provider
needs `redirect_uris: []` despite having no redirect, and its service account needs a `name`.

**No gate group.** A `client` needs one because many humans share one Postman client. A device has its
own service account, so removing *that user* from the target's role group revokes that device and
nothing else. The chart binds the target's role group to the device application directly: the
membership that produces the claim is the one that opens the door.

**Its secret is generated by Authentik and never enters git.** The blueprint deliberately does not set
`client_secret`; Authentik generates one when it creates the provider, and a blueprint leaves an
unmentioned field exactly as it found it, so the value survives every re-apply. Read it once from the
provider page in the UI and put it into that device's firmware.

> The rejected alternative was OpenBao → ExternalSecret → the worker's environment → `!Env` in the
> blueprint. It buys a secret recoverable without the database, and costs a KV path, an ExternalSecret
> entry and an env var per device. Not worth it here: this instance's recovery unit is already the
> Postgres backup plus `AUTHENTIK_SECRET_KEY`, and human group memberships are not in git either — a
> rebuild without the database already means re-granting access by hand. **The cost of this choice:
> rebuild Authentik without its database and every device needs a new secret and a reflash.**

**Token validity is `minutes=10`** by default (`deviceAccessTokenValidity`, overridable per device).
Nothing introspects, so that number *is* the revocation latency, and it can be short because a device
stores nothing durable: hold the token in an ESPHome `global` in RAM, and treat `client_credentials` as
its own refresh — present the secret, get a new token. A reboot costs one extra request.

**Do not fetch a token per API request.** Authentik runs `update_or_create()` on the service account on
every `client_credentials` call, so that is a database write per API call — at a ten-second poll, 8640
a day for one device. Fetch on expiry.

**Devices are emitted last** in the blueprint. Their bindings and service-account memberships are
`!KeyOf` references to the *target's* role groups, and `!KeyOf` only resolves against entries already
applied. This is also why devices are not split into a second ConfigMap key to shorten the apply:
`!KeyOf` does not cross blueprint files, and it would have to become `!Find` on group names — trading a
render-time error for a runtime one.

### Proxies — UIs with no login of their own

Longhorn, Hubble and the Traefik dashboard authenticate nobody: anyone who could resolve the hostname
had full control, and `curl` walks straight past whatever a frontend pretends to enforce. `kind: proxy`
puts Authentik in front of the host itself.

The mechanism is Authentik's **proxy provider** in `forward_single` mode plus an **outpost**. Traefik
asks the outpost about every request through a forwardAuth Middleware: a 2xx passes to the UI, and
anything else — the 302 to the login, a 403 for a non-member — goes back to the browser.

```yaml
  - name: longhorn
    title: Longhorn
    kind: proxy
    hostPrefix: longhorn
    roles:
      - admin
    environments:
      - { cluster: server2, stage: production }
```

**One gate role, not a ladder.** These UIs have no RBAC of their own, so rungs would grant nothing they
could tell apart. Membership of `<slug>-admin` *is* access to the UI — and like every other membership,
it is UI work rather than git.

**Authentik owns the OAuth2 half.** `ProxyProviderSerializer.create()` and `update()` both call
`set_oauth_defaults()`, which rewrites `client_type`, `grant_types`, `signing_key`, `redirect_uris` and
the property mappings on every apply. The chart therefore sets only `mode`, `external_host`, the two
flows and `access_token_validity`; anything else would be overwritten by that same save, and the two
writers would fight forever. Measured on the first apply: `client_type: confidential`, grants
`authorization_code, client_credentials, password`, and the shipped
openid/profile/email/entitlements/proxy mappings. That grant list is upstream's, not a choice of ours.
The local `homelab profile` / `homelab roles` pair is **not** bound: nothing reads a token from a proxy
provider, because the outpost holds the session and the UI behind it never sees one.

**One outpost per cluster, deployed by hand.** Every cluster with a proxy entry gets
`homelab-proxy-<cluster>`, and the chart writes its `providers` list whole — so a provider assigned to
one of these outposts in the UI is dropped on the next apply. Assign in values, never there. The
embedded outpost on server3 is deliberately unused: a guarded request on another cluster would cross to
server3 through its Traefik, which trusts no forwarded headers, and the outpost picks its provider by
`X-Forwarded-Host`.

Per cluster that costs three objects, in that cluster's own `gitops/k8s-manifests/<cluster>/traefik/`:

| Object | Why |
|--------|-----|
| `Deployment.authentik-outpost.yaml` | `ghcr.io/goauthentik/proxy`, tag pinned to Authentik's own `targetRevision` — **bump them together** |
| `ExternalSecret.authentik-outpost.yaml` | the API token Authentik mints with the outpost, copied by hand into `secret/<cluster>/authentik-outpost` |
| `ReferenceGrant.authentik-outpost.yaml` | lets guarded HTTPRoutes in other namespaces reach the outpost Service for the callback |

And two per guarded UI, in that UI's own namespace:

| Object | Why |
|--------|-----|
| `Middleware.authentik.yaml` | the forwardAuth call. It must live in the route's namespace — an HTTPRoute `ExtensionRef` is a local reference |
| a second HTTPRoute rule | `/outpost.goauthentik.io/` straight to the outpost, unauthenticated. Without it the login callback is itself forward-authed and handed to the UI, so the login never completes |

**The Traefik dashboard is the exception to that table.** Its route is not hand-written: the chart
renders an IngressRoute, so the Middleware is attached through `ingressRoute.dashboard.middlewares`
in `gitops/helm-values/<cluster>/traefik.yaml`, and the callback needs a whole HTTPRoute of its own
(`k8s-manifests/<cluster>/traefik/HTTPRoute.authentik-outpost.yaml`) because the chart's `matchRule`
covers only `/dashboard` and `/api`. Both objects sit in the `traefik` namespace beside the outpost,
so no ReferenceGrant is involved. Guarding it matters for the same reason `api.insecure` is false:
`/api/http/routers` returns every router, service and middleware in the cluster — verified
unauthenticated on every cluster before the change: 200 with 20 KB of routing table on server1,
12 KB on server3, and server3's routers are Authentik's and OpenBao's own.

Guarded today: Longhorn, Hubble and the Traefik dashboard, all three on all three clusters.

**A tab that was open before the guard — or when the session expired — cannot log itself in.** A
single-page UI retries in the background with `fetch`, and a `fetch` cannot follow the cross-origin
redirect to `auth.irha.cz`: the browser shows a network error ("Failed to fetch", "data streams are
reconnecting") and **no login prompt ever appears**, because the page never navigates. Measured on
hubble.server2, 2026-09-16: the outpost logged a stream of `/auth/traefik` 302s from the browser and
not one callback attempt. A top-level navigation is what starts the login, so a reload is the first
thing to try.

**A reload is often not enough, and that is worth knowing before an hour goes into debugging the
server.** The retry loop does not stop while the tab is open, and each background `fetch` starts its
own auth flow at Authentik — so a login that *does* succeed has its session cookie overwritten by the
next racing flow seconds later. Measured on hubble.server2: a real password login at 19:50:38, one
`POST /api/service-map-stream -> 200` at 19:50:45, then 302s again, with `authorize_application`
events for the same user every ~8s. The provider, application, binding and group all matched
Longhorn's working configuration exactly; a private window logged in first try.

So when a guarded UI will not log in: **close every tab for that host** — the loop has to stop before
anything else helps — then clear the site's cookies, or use a private window. Only after that is it
worth suspecting the server.

It follows that a **session expiring under an open tab looks like an outage** rather than a logout.
That is the real cost of the eight-hour session below, and the reason it is not shorter.

The same cookie race shows up in a gentler form on ordinary logins: parallel tabs or an impatient
reload can overwrite one another's state cookie, and the callback then fails with `oauth state does
not match the session` — seen three times on longhorn.server2 before a clean login succeeded. Reload
once and let it finish.

**Sessions last `proxyAccessTokenValidity` — eight hours.** Verified 2026-09-16 on longhorn.server2:
the outpost's cookie came back `Max-Age=28801`. Long on purpose, because the UIs behind a proxy are XHR-
and websocket-heavy and an expiry mid-page breaks them until a reload. It is also the revocation
latency: removing someone from the gate group bites within eight hours, not at once.

**Verifying a guarded host** — measured on the server2 canary, 2026-09-16:

```bash
# 302 to https://auth.irha.cz/application/o/authorize/?client_id=…
curl -sI https://longhorn.server2.homelab.irha.cz/ | head -1
# 204, answered by the outpost rather than the UI
curl -s -o /dev/null -w '%{http_code}\n' \
  https://longhorn.server2.homelab.irha.cz/outpost.goauthentik.io/ping
```

`ResolvedRefs=True` on the HTTPRoute is what says the cross-namespace callback was permitted. Without
the ReferenceGrant it reads `RefNotPermitted` and the callback fails instead.

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

**One client, every environment.** A `client` or `device` entry renders exactly one Application whose
`aud` names every API in every environment it lists — 18 entries for `postman`. One login, one token,
every API. `api` entries are unchanged: still one Application per environment.

What that costs, stated once: the `roles` claim is `app.role` and carries no environment, so a token
naming several environments carries the union of the holder's roles across them. `qr-manager.admin`
from a sandbox group is indistinguishable from one earned in production. **With identical roles in
every environment this changes nothing** — the claim is the same either way. It starts to matter the
day someone holds a higher role in sandbox than in production.

The roles mapping enumerates **exact** group→claim pairs rather than stripping a prefix. That is not
tidiness either: a client named `interactive-map` matched `interactive-map-feeder-…-reader` on a prefix
rule and emitted `interactive-map.feeder-server1-production-reader` as a role. Any client whose name
prefixes another application's name hits it, and the chart now refuses that collision among `api`
entries, which still use the prefix rule.

**The API side needs one row.** `issuer_mode` is `per_provider`, so `iss` stays `postman` however wide
`aud` is: every API needs a trusted-issuer row for `https://auth.irha.cz/application/o/postman/` — the
same value in every deployment, one row, not one per environment. That is `homelab-apps` config, and
nothing works end to end until it lands.

**In Postman** it is one collection-level OAuth 2.0 config, and nothing about it varies by environment:

| Field | Value |
|-------|-------|
| Grant type | Authorization Code (With PKCE), `S256` |
| Auth URL | `https://auth.irha.cz/application/o/authorize/` |
| Access Token URL | `https://auth.irha.cz/application/o/token/` |
| Client ID | `postman` |
| Client Secret | *empty* — public client |
| Callback URL | `https://oauth.pstmn.io/v1/callback` |
| Scope | `openid profile email roles` — `roles` is **not** implied by `profile` |

### Setting it up in Postman, step by step

One config on the **collection**, and one Postman environment per homelab environment. Do this once.

1. **Create a Postman environment per homelab environment** you will call — `server1-sandbox`,
   `server1-production`, `server3-production`, `local`. Each needs one variable, the API host:

   | Variable | Example (`server1-sandbox`) |
   |---|---|
   | `baseUrl` | `https://apps.sandbox.server1.homelab.irha.cz` |

   The client id does **not** vary: there is one `postman` client for every environment.

2. **Ask an Authentik admin to add you to `postman-user`.** One group, once. Without it Authentik
   completes the login and then shows *Permission denied* — no token is issued. This is the one step
   that is not in git, deliberately.

3. **On the collection** (not on individual requests), open *Authorization* and choose **OAuth 2.0**,
   then set:

   | Field | Value |
   |---|---|
   | Add auth data to | Request Headers |
   | Grant type | Authorization Code (With PKCE) |
   | Callback URL | `https://oauth.pstmn.io/v1/callback` |
   | Authorize using browser | off (leave the callback above) |
   | Auth URL | `https://auth.irha.cz/application/o/authorize/` |
   | Access Token URL | `https://auth.irha.cz/application/o/token/` |
   | Client ID | `postman` |
   | Client Secret | *(leave empty)* |
   | Code Challenge Method | SHA-256 |
   | Scope | `openid profile email roles` |
   | Client Authentication | Send client credentials in body |

   Two of those are load-bearing. **Client Secret must stay empty** — these are public clients, and
   Postman sending an empty secret as Basic auth is what "Send client credentials in body" avoids.
   **`roles` must be in the scope string**: it is a separate scope mapping, not part of `profile`, and
   without it the token carries no roles and every API answers `403`.

4. **Set each request's URL from the environment** — `{{baseUrl}}/iot/qr-manager/...` — and leave its
   own Authorization on *Inherit auth from parent*. That is what makes switching environment switch
   both the API and the credential together.

5. **Get a token once**: *Get New Access Token* → a browser window → log in to Authentik → *Use
   Token*. That single token is valid at every API in every environment, so switching Postman
   environment needs no new token — only the `baseUrl` changes.

6. **Check what you got** before blaming an API. Paste the token into any JWT decoder and confirm:
   - `aud` contains the API you are calling — it should list all 18 client ids
   - `iss` is `https://auth.irha.cz/application/o/postman/`
   - `roles` names the target applications (`qr-manager.admin`), not `postman.user` alone
   - `exp` — 30 minutes out

**When it expires, log in again.** These clients have no refresh token on purpose, so Postman cannot
renew silently; *Get New Access Token* is the whole recovery. If a request starts returning `401`
after half an hour, that is expiry, not a broken config.

**`401` vs `403`.** A `401` means the API did not accept the token at all — usually that API has no
trusted-issuer row for `postman` yet. A `403` means the token was accepted and
the `roles` claim did not carry what the route wanted — check the claim, then your group memberships in
the *target* application, not in `postman`.

The gate group `postman-user` is the only membership Postman itself needs. It grants no API
access: what the token can *do* still comes from the target applications' own role groups. It is the
switch that revokes Postman in one environment without touching anyone's application roles, and the
only revocation faster than token expiry.

## OpenBao

The OpenBao UI logs in through Authentik via OpenBao's own `oidc` auth method. The Authentik side is the
`openbao` entry in the matrix; the OpenBao side is Terraform: the `vault-config` stage
([`iac/clusters/server3/vault-config/`](../iac/clusters/server3/vault-config/main.tf), module
[`iac/modules/vault-config/`](../iac/modules/vault-config/oidc.tf)).

**Why confidential.** OpenBao's jwt/oidc method refuses an `oidc_client_id` without an
`oidc_client_secret` and has no PKCE-only mode, so this is the one `api` entry with `confidential: true`.
Authentik generates the secret. It is copied once into KV at `secret/server3/openbao`, and Terraform
reads it ephemerally and passes it as a write-only argument, so it is **never in Terraform state**. No
ExternalSecret: OpenBao is its only consumer.

**The fallback stays.** Authentik's own secrets come from OpenBao, so OpenBao must never *need* Authentik
to be administered. Keep `userpass` and the root token working; this adds a login, it replaces none.

| Claim | OpenBao external group | Policy | Grants |
|-------|------------------------|--------|--------|
| `openbao.admin` | `openbao.admin` | `oidc-admin` | everything — `sys/`, `auth/`, policies, KV |
| `openbao.editor` | `openbao.editor` | `oidc-editor` | KV v2 read/write/delete under `secret/` |
| `openbao.reader` | `openbao.reader` | `oidc-reader` | KV v2 read under `secret/` |

The ladder does the rest: an `openbao-server3-production-admin` member's token carries all three claims,
so OpenBao attaches all three policies. The policy documents live in
[`iac/clusters/server3/vault-config/policies/`](../iac/clusters/server3/vault-config/policies/).

**Only the UI callback is registered.** The CLI's `http://localhost:8250/oidc/callback` is not — a
loopback URI on a production client is what `local` environments exist to avoid. For the CLI, log in on
the UI, *Copy token* from the user menu, then `bao login <token>`.

### Setting it up

Once, after the blueprint has landed. On a fresh server3 this is [docs/iac.md](iac.md) step 6, the last
step of the build.

```bash
# Admin session — userpass or root, NOT oidc (this is what creates it)
export VAULT_ADDR=https://vault.server3.homelab.irha.cz
bao login -method=userpass username=<admin>
export VAULT_TOKEN=$(cat ~/.vault-token)

# Provider exists? 404 until the blueprint has landed:
curl -s -o /dev/null -w '%{http_code}\n' \
  https://auth.irha.cz/application/o/openbao-server3-production/.well-known/openid-configuration

# Client secret: Authentik UI → Applications → Providers → openbao-server3-production → Edit
read -rs S && bao kv put secret/server3/openbao oidc-client-secret="$S"; unset S

cd iac/clusters/server3/vault-config
terraform init && terraform plan && terraform apply
terraform plan     # must come back clean
```

The apply creates:

- the `oidc` auth mount, listed on the login page
- the `authentik` role: `groups_claim=roles`, scopes `profile email roles`, audience bound to the
  client_id, UI callback only, 1h/8h tokens. `roles` is not implied by `profile`; without it every
  login succeeds with only the `default` policy
- the three `oidc-*` policies
- one external group plus one group alias per claim

Then add yourself to `openbao-server3-production-admin` in Authentik.

**Verify:** open `https://vault.server3.homelab.irha.cz/ui/`, method *OIDC*, role empty, *Sign in with
OIDC Provider*. Then *Copy token* and run `bao token lookup` with it: `identity_policies` must list
`oidc-admin`, `oidc-editor`, `oidc-reader`. Only `default` means the `roles` claim did not arrive — check
`oidc_scopes` first, then group membership.

**Rotating the secret:**

1. Authentik *Regenerate*.
2. `bao kv put secret/server3/openbao oidc-client-secret=…`.
3. Bump `oidc_client_secret_version` in `iac/clusters/server3/vault-config/main.tf`.
4. `terraform apply`.

The bump is not optional: a write-only value is never read back, so without it the plan is empty and
OpenBao keeps the old secret. Between *Regenerate* and the apply, every OIDC login fails.

**A mount created by hand first** (the pre-Terraform runbook) makes the apply fail with "path is already in
use". Import it (`terraform import module.vault_config.vault_jwt_auth_backend.oidc oidc`, and likewise the
role, policies, groups and aliases) or disable it first. Never disable ESO's `kubernetes-*` mounts that
way: that breaks every ExternalSecret.

## Mealie

The recipe manager on server1 logs in through Authentik with its own built-in OIDC support. The
Authentik side is the `mealie` entry in the matrix; the Mealie side is env on its Deployment
([`gitops/k8s-manifests/server1/mealie/Deployment.yaml`](../gitops/k8s-manifests/server1/mealie/Deployment.yaml)).

**Why confidential.** Mealie's `OIDC_FEATURE` property (`mealie/core/settings/settings.py`, read at the
`v3.27.0` tag) requires `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_CONFIGURATION_URL` and
`OIDC_USER_CLAIM` to all be non-`None`, and otherwise disables OIDC with "Missing required values for
[…]". There is no PKCE-only mode, so this is the second `api` entry with `confidential: true`. Unlike
OpenBao, the secret has a Kubernetes consumer, so it goes KV → ExternalSecret → env.

**Two rungs, not three.** Mealie has exactly two levels: `OIDC_USER_GROUP` gates who may log in and
`OIDC_ADMIN_GROUP` grants admin. A middle rung would be a claim nothing reads. `admin` inherits `user`,
so an admin's token carries both and passes the gate.

| Claim           | Mealie reads it as  | Effect                  |
|-----------------|---------------------|-------------------------|
| `mealie.user`   | `OIDC_USER_GROUP`   | may log in at all       |
| `mealie.admin`  | `OIDC_ADMIN_GROUP`  | becomes a Mealie admin  |

**`OIDC_SCOPES_OVERRIDE` is required, not optional.** Mealie asks for `openid profile email` by default,
which does **not** include this chart's `roles` scope — and without that scope the claim never arrives,
so `OIDC_USER_GROUP` refuses every login. The Deployment requests `openid profile email roles`.

**`email_verified` is required** since Mealie v3.21.0: it matches an OIDC login to an account by the
`email` claim, so it refuses an IdP that lets a user self-assert an address. Authentik emits the claim
with the `email` scope, so nothing extra is needed — but if logins fail with
`[OIDC] email_verified claim is missing or false`, that is why.

**Local logins stay enabled** (`ALLOW_PASSWORD_LOGIN=true`) while this is a trial: the first admin is a
local account, and closing that door behind an untested integration leaves no way in. Flip it once an
Authentik login has worked.

### Setting up the client secret

Once, after the blueprint has landed. The secret is the only manual step — the blueprint deliberately
does not set `client_secret`, so Authentik generates one and a re-apply never disturbs it.

```bash
# Provider exists? 404 until the blueprint has landed:
curl -s -o /dev/null -w '%{http_code}\n' \
  https://auth.irha.cz/application/o/mealie-server1-production/.well-known/openid-configuration

# Client secret: Authentik UI → Applications → Providers → mealie-server1-production → Edit
export BAO_ADDR=https://vault.server3.homelab.irha.cz
read -rs S && bao kv patch secret/server1/mealie oidc-client-secret="$S"; unset S
```

`patch`, **not** `put`: `put` replaces the whole path and would drop `postgres-password`, which is the
password of a running database.

ESO picks it up within its refresh interval (or force it:
`kubectl --context admin@server1 -n mealie annotate externalsecret mealie-oidc force-sync=$(date +%s) --overwrite`),
Reloader restarts the pod, and the login button appears. Until then the `mealie-oidc` ExternalSecret
reports `SecretSyncedError` and Mealie runs on local accounts — the Deployment's `envFrom` is
`optional: true` precisely so this ordering is safe.

## Headlamp

Headlamp authorizes **nothing** itself. It forwards the id_token to kube-apiserver, and the API server
accepts or rejects it. So "Headlamp OIDC" is three pieces, one per layer, and all three must agree:

| Layer | Where | What |
|-------|-------|------|
| Authentik | `headlamp` entry in the matrix | one **public** client per cluster, callback `/oidc-callback` |
| kube-apiserver | `apiserver_oidc` in `iac/clusters/<cluster>/bootstrap/main.tf` | trusts **that cluster's** issuer only |
| Kubernetes RBAC | `gitops/k8s-manifests/<cluster>/headlamp/ClusterRoleBinding.headlamp-oidc.yaml` | `headlamp.admin/editor/reader` → `cluster-admin` / `edit` / `view` |

plus `config.oidc` in `gitops/helm-values/<cluster>/headlamp.yaml` for Headlamp itself.

The identity kube-apiserver builds: username `oidc:<authentik username>` (claim `sub`, prefixed so it can
never collide with a ServiceAccount), groups from the `roles` claim with **no** prefix. The bindings name
those claim values literally, so renaming a rung in the matrix renames a Kubernetes group.

**Public + PKCE, not confidential.** Chart 0.45.0 omits `-oidc-client-secret` entirely when
`clientSecret` is empty, so there is no secret to wire from OpenBao to server1 or server2.

**extraArgs, not structured authentication.** Talos 1.13's schema rejects
`cluster.apiServer.authenticationConfig` as an unknown key (checked with a pinned v1.13.10 `talosctl`,
not the local 1.14 client). `--oidc-*` flags allow one issuer per apiserver, which is exactly the
topology. Revisit after the Talos 1.14 upgrade.

**Order matters, per cluster:** blueprint → apiserver → Headlamp values. Headlamp values landing before
the apiserver trusts the issuer means a 401 on every login.

Rolled out 2026-09-17, server2 → server1 → server3.

### Traps

- **The issuer's trailing slash is load-bearing.** kube-apiserver compares `--oidc-issuer-url` to `iss`
  exactly. Check against the live document:
  `curl -s https://auth.irha.cz/application/o/headlamp-<cluster>-production/.well-known/openid-configuration`.
- **Set `callbackURL` explicitly.** Behind a proxy Headlamp derives it from `X-Forwarded-Proto`, and a
  derived `http://` fails Authentik's strict match.
- **Ask for `roles`.** It is not implied by `profile`; without it every login lands in no group and RBAC
  grants nothing.
- **"Modifications complete after 0s" does not mean staged.** The apply is async; kube-apiserver restarts
  after Terraform returns. And a genuinely staged change would also return instantly. Check the node.
- **The kube-apiserver mirror pod lies.** On Talos, `kubectl get pod kube-apiserver-… -o yaml` kept its
  old UID, a start time days old and no `--oidc` flags long after the restart. It cannot verify flags.

### Verifying

```bash
TC=iac/clusters/<cluster>/credentials/talosconfig; IP=<node ip>
# the flags the running apiserver was started with -- NOT the mirror pod
talosctl --talosconfig $TC -n $IP -e $IP get staticpods kube-apiserver -o yaml | grep -- --oidc
# the authenticator initialising
talosctl --talosconfig $TC -n $IP -e $IP logs -k kube-system/<apiserver pod>:kube-apiserver | grep 'OIDC:'
# RBAC, without any token
kubectl auth can-i delete pods -A --as=oidc:probe --as-group=headlamp.reader   # no
# after a real login: the API server's own record of who it was
talosctl --talosconfig $TC -n $IP -e $IP read /var/log/audit/kube/kube-apiserver.log | grep '"username":"oidc:'
```

In zsh, spell the `talosctl` flags out. Packing them into one variable (`T="--talosconfig … -n …"`)
passes a single argument, and every call fails silently with empty output.

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
- **Do not run `ak apply_blueprint` by hand while the scheduled apply is running.** Two importers on
  the same blueprint contend on row locks, and the loser sets `BlueprintInstance.status` to `error`
  even though the content is fine — observed repeatedly on 2026-09-09, recovering to `successful` on
  the next uncontended scheduled run. Reach for a manual apply only to read an error message, and
  expect the status to flap while you do.
- **Discovery is a cron, not a timer, and it applies only on a changed hash.**
  `blueprints_discovery` runs at `57 * * * *` (read from `Schedule.objects` on 2026-09-17), computes
  the mounted file's hash, and applies only if it moved. So a push can wait up to an hour, and
  `BlueprintInstance.last_applied` reading ten hours old is **correct**, not stuck. An earlier version
  of this line said "~15 minutes, the discovery timer being ~10 min of it" — there is no such timer.
- **The discovery run that fires right after ArgoCD writes the ConfigMap can read the OLD file.** The
  kubelet takes up to a minute to propagate a ConfigMap into a mounted volume. Measured 2026-09-17:
  ArgoCD wrote it at 05:32:2x, discovery ran at 05:32:31 and left `last_applied` on the previous day,
  and the change did not land until the following run. **A discovery that completes is not proof your
  change applied** — compare `last_applied`, or query the objects.
- **To force one, enqueue discovery rather than importing by hand:**
  `ak shell -c "from authentik.blueprints.v1.tasks import blueprints_discovery; blueprints_discovery.send()"`.
  That goes through the worker's queue, so it cannot contend with the scheduled apply the way a
  second importer inside `ak apply_blueprint` does (see above). `.send()` only enqueues: the row sits
  at `queued` in `authentik.tasks.models.Task` until the worker picks it up, which took ~10 minutes
  once — `queued` is not a failure.
- The import is **one transaction**, so the objects appear all at once at the end — an empty query
  midway means "still running", not "failed". Once it does run, the import itself took ~5 min for
  this matrix.
- **Removing an application is TWO commits, because blueprints do not prune.** Deleting an entry
  from the matrix stops *managing* its objects; it does not delete them. On 2026-09-13, removing the
  IoT estate from server2 left six OAuth2 providers **with live credentials** behind — invisible to
  git, and deleted by hand in the UI afterwards. So:
  1. set `state: absent` on the entry and change **nothing else**. The chart re-renders the same
     slugs as deletion entries — Application first (its policy bindings are CASCADE and go with
     it), then the provider (`Application.provider` is `SET_DEFAULT`, so deleting it first would
     leave a provider-less Application), then each role group (`Group.parents` is m2m, so a parent
     deletion only drops the relation), plus a client's or device's own mapping pair, a device's
     service account, and the cluster's outpost if its last proxy just went.
  2. once that apply has landed, delete the entry from the matrix.

  Keep `roles` and `environments` on the way out — they are how the chart knows which group names
  and slugs to delete. The chart refuses an absent entry with no `roles` for exactly that reason,
  and refuses a present client or device still naming an absent application in `accesses`.
  Step 2 is safe to delay: Authentik's ABSENT branch deletes the instance if the identifiers find
  one and logs *"Entry to delete with no instance, skipping"* if they do not, so a spent deletion
  entry is a no-op on every later apply.
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
| OpenBao side of OpenBao's OIDC login | [`iac/clusters/server3/vault-config/`](../iac/clusters/server3/vault-config/main.tf) — [docs/iac.md](iac.md) step 6 |
