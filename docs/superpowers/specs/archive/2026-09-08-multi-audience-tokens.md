# One token, several APIs — the `accesses` mapping

> **SUPERSEDED the same day, on the point below that mattered most.** This spec built `postman` as
> SIX clients, one per environment, to keep the environment-free `roles` claim pinned by `aud`/`iss`.
> That was rejected in use: switching environment meant fetching another token, which is as disruptive
> as logging in again. It is now **one** `postman` client whose audience spans every environment. The
> consequence this spec describes is real and accepted — such a token carries the union of the holder's
> roles across environments — and it is a no-op while roles are identical everywhere, which they are.
> Current design: `docs/superpowers/specs/2026-09-08-device-identity-esp32.md` and `docs/identity.md`.

**Status: built and applied 2026-09-08.** The six `postman` applications, their providers, gate groups,
bindings and per-client scope mappings exist on `authentik-server3` — verified in its database, see
*Evidence*. The other half — the trusted-issuer rows — is `iot-miniservers` work and has not started,
so **no API accepts one of these tokens yet**. See *What is left*.

**Related:** [`archive/2026-09-04-authentik-tenancy-topology.md`](archive/2026-09-04-authentik-tenancy-topology.md),
which named this design without building it, and
[`archive/2026-09-08-role-hierarchy.md`](archive/2026-09-08-role-hierarchy.md), whose ladder arrives
through a broad token unchanged.

---

## The problem in one paragraph

A token minted for client `X` carries `aud: ["X"]` and `iss: .../X/`. Each API trusts exactly the
`(iss, aud)` pair of its own application. So a `postman` client's token carried `aud: ["postman"]`,
matched no API's trusted-issuer row, and reached nothing — a `401` everywhere. For one client to call
several APIs, its token must name each of them.

## The thing that was nearly missed

The spec that opened this question framed it as widening `aud`. That is half the work, and the smaller
half. The shared `homelab roles` mapping filters on the **issuing** `client_id`:

```python
prefix = f"{provider.client_id}-"
```

For a `postman` client that collects groups named `postman-*` and nothing else. Widen `aud`, add the
trusted-issuer rows, and every request now gets *past* the verifier and dies at
`@RequireRoles('qr-manager.reader')` instead. **`accesses` is two claim changes, not one**, and the
roles half is the one that decides whether the token can do anything.

Groups name the **resource**, not the client that logs in — so a broad client's `roles` claim is
collected from its targets' groups. `qr-manager.editor` means *may create QR codes* whichever client
the user arrived through.

## The hazard that fixed the shape: one client per environment

The obvious build is one `postman` client whose audience spans everything. It is a privilege
escalation, and nothing about it looks misconfigured.

The `roles` claim is **environment-free by construction** — `qr-manager.admin` is the same string in
every cluster and stage, deliberately, so an API's route constant does not vary by deployment. What
pins a token to an environment is `aud` and `iss`, and nothing else. So for a user holding
`qr-manager-server1-sandbox-admin` and `qr-manager-server2-production-reader`, a client spanning both
environments issues:

```json
"aud":   ["postman", "...", "qr-manager-server2-production", "..."],
"roles": ["qr-manager.admin", "qr-manager.reader"]
```

The **production** API verifies `aud`, verifies `iss`, reads `qr-manager.admin`, and grants it. That
admin came from a sandbox group.

Hence: **`accesses` resolves within one environment only**, and there is one broad client per
environment. `postman-server1-sandbox`, `postman-server1-production`, `postman-server2-sandbox`,
`postman-server2-production`, `postman-server3-production`, `postman-local`. This costs nothing in
use: Authentik's authorize and token endpoints are shared across providers, so in Postman it is one
collection-level OAuth config with the `client_id` as a per-environment variable.

## What the four open questions resolved to

1. **Where the audience list comes from.** A static list in the values matrix, resolved and **baked as
   literals at chart render time** — no model lookups inside a property mapping expression. Declared
   once as a superset; each environment gets the intersection with what actually runs there, so
   `postman-server3-production` correctly addresses `homelab-dashboard` alone. Rejected: deriving the
   audience from group membership, which would make `aud` user-dependent and let a group edit silently
   rewrite audiences. **The list is the ceiling; the policy binding is the grant** — that split is what
   makes it read like a privilege.
2. **Whether `roles` still works.** Not as shared — see above. A broad client binds its own copies of
   *both* mappings, with a `{client_id: short_name}` table baked in. Every prefix in that table ends in
   the same environment suffix. `all_groups()` still returns ancestors, so a target's ladder arrives
   whole.
3. **What stops the list growing.** Reframed: growth was not the risk, **lifetime** was. Nothing here
   introspects — every verifier checks the signature offline — so expiry is the only revocation there
   is, and `offline_access` would have made a credential worth N APIs effectively permanent. Broad
   clients get `grant_types: [authorization_code]` and no refresh token; logging in again is the price,
   and it is what keeps a group removal meaningful. Explicit consent was considered and **dropped**: at
   30-minute re-logins it is friction six times an hour, and the audience list is reviewed in git.
4. **Whether `-local` clients keep their narrow shape.** Enforced, not documented: an application that
   declares `accesses` may not be named as anyone's target, and vice versa. Clients are clients and
   APIs are APIs, and `helm template` fails on the overlap — so the tempting one-line edit that gives
   `qr-manager-local` an `accesses` list does not render.

## What got built

`gitops/helm-charts/authentik-blueprints/templates/configmap.yaml`:

- `accesses` marks an application **client-only**: it brings `redirectUris` and forbids
  `host`/`hostPrefix`/`basePath`, gets no `meta_launch_url` and no logout redirect URI.
- Per-client copies of `homelab profile` and `homelab roles`, bound **instead of** the shared pair —
  binding both would duplicate `aud`, which Authentik merges by concatenation.
- `grant_types` drops `refresh_token` for client-only apps.
- Five `fail`s: unknown target, self-reference, client/API overlap, missing `redirectUris`, a host
  alongside `accesses`, plus one per environment that resolves to no targets.

`gitops/helm-values/server3/authentik-blueprints.yaml`: the `postman` entry, six environments, one
`user` role that exists only as the access gate — an Application with no binding is readable by every
user.

Public client + PKCE, so there is no secret and none of this needed OpenBao.

## Evidence

- `helm template` against the real matrix renders, `helm lint` clean, and diffing the output against
  the same render at `HEAD` shows **zero removed lines**: every existing application is byte-identical,
  every change is an addition.
- The generated blueprint parses as YAML, has no duplicate entry `id`s or scope-mapping names, and
  every `!KeyOf` reference is defined by an earlier entry — which is what `!KeyOf` requires.
- Audience audit over all 23 providers: the 17 existing ones still emit `[provider.client_id]`; the six
  `postman` clients each name only their own environment's applications.
- The six rendered `roles` expressions were **executed** against a simulated user holding
  `qr-manager-server1-sandbox-admin` (ladder expanded), `miot-bridge-server1-production-admin` and
  `homelab-dashboard-local-reader`:

  | client | claim |
  |---|---|
  | `postman-server1-sandbox` | `postman.user`, `qr-manager.{admin,editor,reader}` |
  | `postman-server1-production` | `miot-bridge.{admin,editor,reader}` |
  | `postman-local` | `homelab-dashboard.reader` |
  | `postman-server3-production` | *(empty)* |

  The production membership does not appear in the sandbox token, and the sandbox membership does not
  appear in the production one. That is the escalation above, not happening.
- All six `fail` guards fire with their intended message.

Measured on `authentik-server3` after the apply:

- Six applications, six `postman-<env>-user` groups, and **six policy bindings** — none of the new
  applications is unbound, which is the invariant that matters most, since Authentik fails open.
- Every `postman` provider is `public`, `grant_types = {authorization_code}` — no `refresh_token` —
  with the single `https://oauth.pstmn.io/v1/callback` redirect URI. `qr-manager-local` still carries
  `{authorization_code,refresh_token}` and its loopback URIs, so nothing regressed.
- Each one binds `homelab profile (postman-<env>)` and `homelab roles (postman-<env>)` and **not** the
  shared pair; `qr-manager-server1-sandbox` still binds the shared `homelab profile` / `homelab roles`.
  That is the duplicate-`aud` hazard measured as absent.

One operational fact came out of the apply and is now in the docs: a blueprint takes **~15 minutes** to
land, not the ~45s AGENTS.md claimed. Kubelet propagation ~1 min, Authentik's discovery timer ~10 min,
the import ~5 min — and the import is one transaction, so the objects appear all at once at the end.
An empty query midway means "still running".

## What is left

**Here:**

1. ~~Sync~~ — done. Commit `b5711f8`, hard-refreshed, synced, blueprint applied and verified.
2. Add yourself to `postman-<env>-user` in the Authentik UI, per environment. Memberships are not in
   git, and without one the application refuses you at authorization.
3. **Decode a real token.** The duplicate-`aud` risk was specifically about a provider binding both the
   shared `profile` mapping and its own copy; the database says none of them do (below), so this is now
   confirmation rather than an open question. Count the `aud` entries on a token anyway — it is one
   login.

**`iot-miniservers`, and nothing works end to end without it:**

4. A trusted-issuer row per API for `postman-<its own environment>`. `issuer_mode` is `per_provider`,
   so `iss` stays `postman-<env>` however wide `aud` is — without the row the widened audience changes
   nothing. `jose` accepts `issuer` as an array, so this is config, not verifier code.
5. **Same environment only.** A `postman-server1-sandbox` row in a production API's config reverses the
   invariant from the other end and re-opens the escalation this design exists to prevent.
6. `AuthMethod` naming, which was out of scope here and follows whatever this shape turned out to be.

**Not settled, deliberately:** whether `postman-*-production` clients should exist at all. They are
built because the requirement was "all envs, all APIs", and they are the highest-value credential in
this design. If that is ever regretted, deleting the two production environments from the `postman`
entry is a two-line change — plus a manual cleanup, because blueprints do not prune.
