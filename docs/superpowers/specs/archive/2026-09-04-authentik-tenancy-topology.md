# Authentik — Tenancy Topology

**Status:** current. Supersedes the Zitadel topology, deleted 2026-09-04.

**Decision — settled 2026-09-04, do not re-open.** Zitadel, Keycloak and Authentik were each deployed
on server3, exercised against the real requirements, and rolled back. The decision records have been
deleted; this paragraph is what survives of them, and it exists so the question is not re-litigated.

- **Authentik won on per-application access**, which is the deciding requirement ("usable in app 1,
  refused at app 2, refused by the IdP"). It is a group bound to an Application — one object. Keycloak
  needs a copied authentication flow per gated app, with ordering traps that produce a gate which
  *silently does nothing* when assembled wrong. Zitadel gates the *project*, forcing ~20
  projects and invalidating the topology that had been planned for it.
- **The same binding also gates `client_credentials`**, so humans and devices share one mechanism.
- **Zitadel was eliminated** on two further measured facts: its `aud` is client-asserted (a caller can
  address a token to a project it has no grant on, for human *and* machine tokens), and it silently
  ignores input it does not understand — it accepted `audience`, `scopes` and `projectId` on token
  creation with HTTP 200 and applied none of them.
- **Zitadel's PAT — the reason it was originally chosen — is unusable.** An opaque JWE, not
  audience-scopable, reported `active: true` by every API in the instance, requiring an introspection
  call per request. Machine identity is `client_credentials` everywhere.
- **Accepted cost:** Authentik is the heaviest — ~744Mi measured on 2026.8.1 (server 381 + worker 268 + Postgres 95), against Keycloak's 465Mi and Zitadel's
  87Mi — and three components rather than two (server, worker, Postgres; **Redis was removed upstream in 2025.10**). **Fallback if that is ever rejected: Keycloak**, which
  meets every requirement; Zitadel does not.

**Execution:** [`../plans/2026-09-04-authentik-deployment.md`](../../plans/2026-09-04-authentik-deployment.md).

**Name:** `auth.irha.cz`, apex tier, already a SAN on `server3-tls`. Reserved for the IdP before one was
chosen; the choice of product does not change the name, and the `iss` claim it anchors is permanent.

---

## The object model, and how it differs from what was planned

| Level | What it is | Isolation it gives |
| --- | --- | --- |
| **Application** | The thing a user or device is granted access to. Carries the policy bindings | **The access boundary.** No binding = everyone; any binding = only who is bound |
| **Provider** | The OAuth2 client attached to an Application — `client_id`, secret, redirect URIs, token lifetimes | Sets `aud` (always its own `client_id`) and token validity |
| **Group** | Named collection of users and service accounts | The unit of both access and role |
| **Policy binding** | Group (or user, or policy) -> Application | What actually gates |

**The load-bearing difference from the Zitadel plan:** Zitadel's access boundary was the *project*, so
per-application gating forced a project per application per environment — roughly twenty projects.
Authentik gates the Application directly, so the object count is one Application per deployable per
environment and nothing else.

**The same binding gates machines.** Measured: binding a group to an Application causes
`client_credentials` for that Application's provider to fail with `invalid_grant` until the service
account is a member. Humans and devices use one mechanism. This is why the model below has no separate
device concept.

---

## The environment matrix

Unchanged, and re-verified against the repo:

| Cluster | Stages running app workloads |
| --- | --- |
| `server1` | `sandbox`, `production` |
| `server2` | `sandbox`, `production` |
| `server3` | `production` only (control plane: ArgoCD, OpenBao, LGTM, `homelab-dashboard-ui`) |

Five environments on a cluster x stage axis. Per-cluster DNS already exists as
`*.<cluster>.homelab.irha.cz`, with sandbox under `*.sandbox.<cluster>.homelab.irha.cz`.

## Naming

```
Application slug / client_id :  <app>-<cluster>-<stage>
                                qr-manager-server1-sandbox
                                miot-bridge-server2-production
                                homelab-dashboard-server3-production

Group                        :  <app>-<cluster>-<stage>-<role>
                                qr-manager-server1-sandbox-admin
                                qr-manager-server1-sandbox-reader
                                miot-bridge-server2-production-operator
```

**One Application covers a deployable and the API it calls.** `qr-manager-ui` and `qr-manager-api` in
`server1-sandbox` are one Application with one `client_id`; the SPA logs in, receives
`aud: ["qr-manager-server1-sandbox"]`, and the API validates exactly that. The audience is correct
without any per-API configuration — it is the provider's own `client_id`. The one custom part is the
*shape*: the local `profile` mapping emits it as an array, see below.

**Role groups are also the access groups.** Bind every role group for an application to that
application with `policy_engine_mode: any`. Membership in any of them grants access; *which* group
tells the API the role. There is no separate "access" group to keep in sync — the gate and the role
are the same fact.

**Group names carry the environment; the token does not.** Authentik group names are **globally
unique** — verified 2026-09-04: creating `admin` under two different parents is rejected with
"Group with this name already exists". So the objects must be `qr-manager-server1-sandbox-admin` to
stay distinct. None of that belongs in a token, because an API must never authorize on "server1" or
"sandbox". A local `roles` scope mapping strips the `client_id` prefix and re-prefixes with the
application's short name (`Application.group`, set from the values matrix), yielding
`qr-manager.admin` — the same string in every environment.

The mapping also **filters to the issuing application**. Authentik's shipped `profile` mapping emits
every group the user belongs to, unfiltered, so a sandbox token was naming the user's server2
production membership; a local `profile` replacement drops that claim entirely.

**Groups name the RESOURCE, not the client that logs in.** Today they coincide — a UI and the API it
calls share one Application. The distinction is declared now so that a second product's UI calling
`qr-manager-api` is an additive `accesses` list rather than a re-model: `qr-manager.editor` keeps
meaning *may create QR codes*, whichever UI the user arrived through.

**Every provider signs with the same key — so `aud` is the only thing separating applications on the
API side.** Measured 2026-09-04: all five providers return an identical `kid`, and a token minted for
`qr-manager-server1-sandbox` verifies cleanly against `qr-manager-server2-production`'s JWKS URL. A
valid signature proves the token came from this IdP and **nothing about which application it was for**.
This is not a misconfiguration to fix — a shared signing certificate is the default and giving each
provider its own would only move the problem, since nothing binds a `kid` to an application either. It
is a property the verifiers must be written against, and it is why the row above says "mandatory".

`aud` is emitted as a **one-element array** rather than the bare string Authentik defaults to. Both
are valid -- OIDC Core calls the array the general case -- but the shape must not change later, and it
would the day one login may call several APIs. Emitting the array from the start makes
`aud === "<client_id>"` fail on the first request rather than months afterwards.

**One trap for whoever edits the scope mappings:** Authentik merges list-valued claims from several
mappings by **concatenation, not replacement**. Setting `aud` in both local mappings produced
`aud: ["qr-manager-server1-sandbox", "qr-manager-server1-sandbox"]` on a real token. It lives in the
`profile` mapping alone.

## Where each boundary is enforced

| Question | Enforced by | Mechanism |
| --- | --- | --- |
| May this human use this application at all? | **Authentik, at authorization** | Policy binding: group -> Application. Refused with a *Permission denied* page; no code is issued and the SPA receives nothing |
| Which role do they have in it? | **The API** | `roles` claim — `<app>.<role>`, e.g. `qr-manager.admin`. Environment-free by construction, so a route's constant is identical in every cluster and stage |
| Is this token meant for this API? | **The API** | `aud` — server-set to the issuing provider's `client_id` and **not client-assertable** (measured; `audience=`, `resource=` and scope tricks all ignored). Always an **array**, so APIs check membership. **The check is mandatory, see below** |
| May this device call anything? | **Authentik + the API** | The binding gates `client_credentials`; the API then checks `aud`. **What a device token carries as its role claim is not settled** — the shipped `groups` claim is no longer emitted (see Devices below) |

Note the second row's contrast with what was previously planned: under Zitadel the audience check did
not work and the roles claim was the *only* boundary. Under Authentik both work, so an API has two
independent checks.

### Consequences worth stating plainly

- **The gate fires at authorization, not authentication.** A refused user still completes a login and
  then sees *Permission denied*. No token reaches the application either way, but the event log will
  show a successful `login` followed by a refusal — that is expected, not a bug.
- **An unbound Application is open to every user.** Authentik's default is "all users may access".
  A missing binding fails open. Every Application in this topology must carry at least one binding, and
  that is the single most important invariant to check after applying config.
- **The frontend's role check is UX.** Hiding a button is not authorization. The API re-checks.
- **`issuer_mode` is `per_provider` on every provider** — the model default, adopted 2026-09-04 in
  `97605c1`, reversing this document's earlier instruction to set `global`. Each Application issues
  under its own `iss` (`https://auth.irha.cz/application/o/<client_id>/`, trailing slash included).
  The rejected argument was that this puts one row per application in a verifier's trusted-issuer
  table; that is true and small — one row per *deployment*, carrying a per-environment value exactly
  as `apiBaseURL` already does, not N rows per API. What it buys is a second app-scoped discriminator
  that a discovery-built client pins **structurally**, because the client *is* the issuer, where
  `aud` is an optional argument every JWT library lets you omit. It is not a fix for the shared
  signing key and it does not excuse skipping the `aud` check. The reasoning is repeated at the
  `issuer_mode` line in `gitops/helm-charts/authentik-blueprints/templates/configmap.yaml`, which is
  where it is set.

## Devices

A device is an Application with a **confidential** provider and no redirect URIs, plus a group binding.
`client_credentials` with `client_id` + `client_secret` returns a signed JWT verified offline against
the JWKS — the same JWKS the human tokens use.

**The one wrinkle, stated up front because it contradicts a simpler earlier claim.** A device's token
carries `aud: <the device's own client_id>`, not the API's. Two ways to close that, and the first needs
no custom code:

1. **Recommended — the API validates `aud` against a short allowlist** of client_ids permitted to call
   it: its own SPA, plus each device. This is an explicit access list, arguably better than a claim
   check, and it is ordinary configuration.
2. A custom scope mapping (a few lines of Python) that sets `aud` to the target API's identifier,
   applied to device providers. One mapping, reused. Only worth it once the allowlist gets long.

`aud` comes from the provider itself and needs no Python. **The role claim does** — corrected
2026-09-05. This paragraph used to say `groups` arrives from Authentik's shipped `profile` mapping;
that is true of the shipped mapping and **not of these providers**, which bind the local `homelab
profile` mapping instead, and it deletes `groups` deliberately (it listed every group the user held,
across every cluster and stage). The generated providers get `roles` from the local `homelab roles`
mapping, which reads `request.user.all_groups()` filtered to the issuing `client_id`.

So before the first device Application is created, decide and then **verify against a real
`client_credentials` token** which claim carries a device's authorization: the same `roles` mapping
applied to the service account user behind the confidential client, or an `aud` allowlist alone
(option 1 above), which needs no claim at all. Do not assume `groups` — it is not there.

**Token lifetime is per provider** (`access_token_validity`), which matters because EMQX's
`disconnect_after_expire` defaults to true — an expiring token drops the MQTT client. Give device
providers a long validity and leave SPA providers short. Zitadel could not separate these.

### What an ESP32 can actually do

Established against `iot-esphome/interactive-map.yaml`, which is the only HTTP device today — an ESP32
on the `esp-idf` framework fetching a read-only endpoint every 10 seconds over **plain HTTP**.

- **It can perform the token exchange.** ESPHome's `http_request` supports `http_request.post` with a
  body, `!lambda` request headers (so a runtime `Authorization: Bearer …`), `json::parse_json` and
  globals — all four are already used in that file. A token-fetch script plus a refresh `interval` is
  more YAML, not a new capability. **The belief that a dumb device can only hold a static token is
  false**, and it is what originally argued for Zitadel's PAT.
- **TLS is probably available, and was never actually ruled out for HTTP.** The "these chips cannot do
  TLS" belief comes from the *MQTT* decision — the architecture doc's wording is that the Loxone
  Miniserver and "several ESPHome and Arduino **MQTT** clients" cannot do TLS with SNI. That is a
  different component. `http_request` on `esp-idf` does HTTPS, validated against ESP-IDF's bundled CA
  store, with `verify_ssl: false` available for a private CA like this cluster's:

  ```yaml
  http_request:
    id: http_client
    verify_ssl: false   # private CA; disables verification globally on the device
  ```

  That buys encryption without server authentication — it stops passive sniffing of the credential,
  not an active MITM. The real constraint on ESP32 is heap during the handshake, so the test is "does
  it stay up", not "does it compile".
- **This matters more than it looks.** Over cleartext the `client_secret` crosses the wire on every
  refresh, and anyone who captures one refresh can mint tokens indefinitely — **short token lifetimes
  protect nothing against that**. Issue device credentials, but put the transport on TLS in the same
  change, not as a follow-up.
- **For actuators, prefer ESPHome's own encryption over an IdP credential.** `iot-esphome/relays.yaml`
  is described as "direct control over ESPHome API"; the native API takes
  `api: encryption: key: <32-byte base64>` (Noise PSK, cheap on ESP32). That authenticates and encrypts
  the control channel with no OIDC flow, no refresh, and no device secret that also unlocks the HTTP
  APIs.

## MQTT

EMQX 5.x authenticates MQTT against the same JWKS:

```hocon
{ mechanism = jwt
  use_jwks = true
  endpoint = "https://auth.irha.cz/application/o/<slug>/jwks/"
  from = password
  verify_claims = { username = "${username}" } }
```

**Authorization stays in EMQX's `built_in_database`**, keyed on username, exactly as
`gitops/helm-values/<cluster>/provisioner/emqx.yaml` does today. authn and authz are separate sources
in EMQX 5.x, so JWT authentication composes with the existing ACL provisioner untouched. Moving ACLs
into an `acl` claim would require a custom mapping and is not worth it at this scale.

## Service-to-service

**Kubernetes ServiceAccount tokens for same-cluster API-to-API**, not Authentik. They are already
present (`automountServiceAccountToken: false` on every API's SA), genuinely audience-scoped at
issuance, and verified against the apiserver's JWKS:

```
aud: ["qr-manager-api"]   sub: system:serviceaccount:production:api-iot-miot-bridge-api
iss: https://192.168.1.200:6443   lifetime: 600s   RS256
```

That is a stronger audience guarantee than any IdP here gives, because the apiserver mints the audience
rather than echoing a request. The cost is a per-cluster issuer, so reach for Authentik only when a call
crosses a cluster boundary.

## How the config gets applied — settled

**Blueprints.** Authentik reads YAML from `/blueprints`, watches the directory for changes, and applies
them. The whole graph — groups, applications, providers, bindings — lives in git as YAML, mounted from
a ConfigMap, with `stakater/Reloader` (already in this repo) restarting on change.

This resolves the open question the Zitadel topology carried, which weighed a hand-written provisioner
Job against a Terraform provider with local state. Neither is needed: the product reconciles its own
declarative config, and deletion is expressible via `state: absent` rather than being a known gap.

The remaining non-declarative piece is the **bootstrap token** (`AUTHENTIK_BOOTSTRAP_TOKEN`,
`AUTHENTIK_BOOTSTRAP_PASSWORD`), which seeds `akadmin` and belongs in OpenBao like every other secret
here.

## Alternatives rejected

| Option | Why not |
| --- | --- |
| **One Application per deployable, environments as groups** | Inverts the gate: a sandbox grant would authenticate against production, and redirect URIs could not differ per environment. Wrong boundary on the axis that matters |
| **Separate Authentik per cluster** | True isolation, three Postgres to back up, three upgrade paths. Revisit only if a cluster must survive server3 being down |
| **Authentik's proxy provider for the SPAs** | Forward-auth was dropped as a requirement 2026-08-31; the frontends do in-app OIDC. It survives as a candidate for one thing only — see below |
| **A separate device IdP or token service** | The standing constraint against hand-rolled key management, and Authentik gates devices with the same primitive as humans |

## Still open

- **`homelab-dashboard-ui` `/proxy/network/`.** Reachable by anyone who can resolve the host, serving
  UniFi behind an nginx-injected key; in-app login cannot close it because `curl` skips React. Authentik's
  **proxy provider** covers this natively and is the reason it is worth having. Not required for any
  earlier stage — decide when the rest is stable.
- **`interactive-map-feeder-api` clusters.** It has `sandbox`/`production` values but no cluster
  manifests were read during this write-up. Confirm before generating its Applications.
- **Group sprawl.** `<app>-<cluster>-<stage>-<role>` is precise and verbose. At five environments and
  four deployables it is fine; revisit if it passes a few dozen.
