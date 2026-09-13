# Devices in the IdP — `kind: device`

**Status: built and applied 2026-09-09, verified with a real token.** The chart carries `kind` and the device shape; the matrix
carries `interactive-map` as the first device. Nothing exists on `authentik-server3` yet, and the
device cannot use it until the TLS question below is answered.

**Related:** [`archive/2026-09-04-authentik-tenancy-topology.md`](archive/2026-09-04-authentik-tenancy-topology.md)
(its *Devices* section, which this supersedes) and
[`archive/2026-09-08-multi-audience-tokens.md`](archive/2026-09-08-multi-audience-tokens.md), whose
`accesses` mechanism removes the awkward half of the old device design.

---

## The secret: reversed during implementation

This spec first recommended OpenBao → ExternalSecret → the worker's environment → `!Env` in the
blueprint, on the grounds that secrets live in OpenBao here. **That was over-engineered and it is not
what got built.**

Authentik generates a `client_secret` when it creates the provider. The blueprint simply does not
mention the field, and a blueprint leaves an unmentioned field exactly as it found it — so the value
is stable across every re-apply. Read it once from the provider page and put it in the device firmware.

The argument that changed it: this instance's recovery unit is **already** the Postgres backup plus
`AUTHENTIK_SECRET_KEY`, and human group memberships are deliberately not in git either. A rebuild
without the database already means re-granting access by hand. A device secret is the same class of
fact, so keeping it in the database costs nothing that was not already accepted, and saves a KV path,
an ExternalSecret entry and an env var per device.

**What the choice costs:** rebuild Authentik without its database and every device needs a new secret
and a reflash. Revisit if devices ever outnumber the people who could reflash them.

## What changed since the old design

The tenancy spec recommended that each API validate `aud` against **an allowlist of client_ids**,
because a device's token carries its own `client_id` rather than the API's. That workaround is no
longer needed. `accesses` shipped on 2026-09-08: a device application declaring
`accesses: [interactive-map-feeder]` gets

```
aud: ["interactive-map-device-<env>", "interactive-map-feeder-<env>"]
```

so the API does the same `aud` check it already does for every human client, with no allowlist and no
per-API special case. **Prefer `accesses`; do not build the allowlist.**

## The mechanic that decides the shape

Read out of `providers/oauth2/token/client_credentials.py` at the deployed version. Authentik supports
four `client_credentials` methods; the plain-OAuth one — `client_secret` equal to the provider's own
secret — does this:

```python
def post_init_client_credentials_generated(self, request):
    app = Application.objects.filter(provider=self.provider).first()
    self.user, _ = User.objects.update_or_create(
        username=f"ak-{self.provider.name[: USERNAME_MAX_LENGTH - 22]}-client_credentials",
        defaults={..., "type": UserTypes.SERVICE_ACCOUNT},
    )
    self.check_policy_access(app, request)
```

Three consequences, and they are the whole design:

1. **The token's user is auto-created on first request, in no groups.** Our `roles` mapping reads
   `request.user.all_groups()`, so a freshly generated service account yields an **empty `roles`
   claim** — and `check_policy_access` then refuses it against the Application's bindings, which the
   chart always generates. Built naively, the first token request fails, and it fails *after* creating
   the user.
2. **The username is deterministic**: `ak-<provider name>-client_credentials`. So the service account
   can be **pre-created in the blueprint**, already in the right groups. `update_or_create` matches it
   by username and only overwrites `name`/`path`/`type`/`last_login` — group membership survives. That
   turns the whole thing declarative except the secret.
3. **Policy access is checked after the user is resolved**, so a pre-created member passes on the first
   try.

**Verify before building:** create the provider, make one `client_credentials` request, and read the
username Authentik actually generated. `USERNAME_MAX_LENGTH` truncation is irrelevant at our name
lengths, but the pre-created username must match *exactly* or the blueprint user is silently ignored
and a second, group-less one appears beside it.

## What the device needs to be a member of

Two groups, and the distinction is the same one `accesses` rests on:

| Group | Why |
|---|---|
| `interactive-map-device-<env>-gate` (its own) | Passes the Application's policy binding. Without a binding the app is open to every user; this is the revocation switch |
| `interactive-map-feeder-<env>-reader` (the target's) | What puts `interactive-map-feeder.reader` in the claim. Groups name the RESOURCE, so this is the same group a human reader holds |

Both can be blueprint-declared on the pre-created service account, so neither is UI work — unlike human
memberships, which stay out of git on purpose. A service account is not a person.

## What got built

`kind` in the values matrix, ours rather than Authentik's `client_type` (which is derived from it):

| | `api` (default) | `client` | `device` |
|---|---|---|---|
| Authentik `client_type` | public | public | confidential |
| Grants | code + refresh | code | client_credentials |
| Redirect URIs | from the host | `redirectUris` | none |
| Roles claim from | own groups | the human's groups | the role named in `accesses` |
| Environments | many | many | many — one client each |

The `client`/`device` split is *whose groups fill the roles claim*. A client borrows the human's, so it
names bare applications; a device has no human, so each access names a role — which is also what makes
"many devices, each reaching different APIs" a per-device fact rather than a fleet-wide one.

**The service account is declared, not left to Authentik.** `client_credentials` does
`update_or_create()` on `ak-<provider name>-client_credentials` and creates it in **no groups**. Left
alone the first token request yields an empty `roles` claim and is then refused by the bindings, after
creating the user. The chart emits that user first, in the target's role group; `update_or_create` then
matches by username and overwrites only name/path/type, so membership survives.

**No gate group for devices.** A `client` needs one because many humans share one Postman client. A
device has its own service account, so removing that user from the target's role group revokes that
device alone. The chart binds the target's role group straight to the device application.

**Devices are emitted last.** Their bindings and memberships are `!KeyOf` references to the target's
groups, which must already be applied. This is also why the blueprint was **not** split into a second
ConfigMap key to shorten the ~5-minute apply, as this spec originally proposed: `!KeyOf` does not cross
blueprint files. It would have to become `!Find` on group names, trading a render-time failure for a
runtime one. The apply-duration problem is real and still open — see below.

### One guard was wrong and is gone

The first build enforced **exactly one environment per device**, justified with the cross-environment
escalation that shaped the `postman` split. That reasoning does not apply. A device declaring two
environments renders *two clients* — separate `client_id`, secret, service account and
single-environment audience — which is the same shape the escalation argument produced, not a violation
of it. The guard forbade the useful case (a `local` credential for a bench beside a deployed one) while
preventing nothing. Removed; `interactive-map` now declares `server1/production` and `local`.

The chart carries 23 render-time `fail`s; thirteen are exercised by fixtures, and seven were added
for `kind`: unknown kind, `accesses` on an `api`, a bare access on a device, a map access on a client,
a role the target does not declare, a device with `roles`, and a device with `redirectUris`.

### Verified

- Renders and lints, and every `api` application is byte-identical to the previously applied blueprint.
- The generated blueprint parses, has no duplicate ids, every `!KeyOf` resolves to an earlier entry,
  and **no application is unbound** — 19 applications, all bound. (It read 24 when `postman` was still
  six per-environment clients; that collapsed to one on 2026-09-09.)
- The device's rendered `roles` expression, executed against simulated memberships:

  | service account is in | claim |
  |---|---|
  | `interactive-map-feeder-server2-production-reader` (as provisioned) | `interactive-map-feeder.reader` |
  | the **sandbox** reader group instead | *(empty)* |
  | the production admin ladder | `.admin`, `.editor`, `.reader` |
  | no groups — the trap this design avoids | *(empty)* |

### Verified on the instance, with a real token

A `client_credentials` request against `interactive-map` returned:

```
iss:   https://auth.irha.cz/application/o/interactive-map/
sub:   ak-interactive-map-client_credentials
aud:   ["interactive-map", "interactive-map-feeder-server1-production",
        "interactive-map-feeder-local"]
roles: ["interactive-map-feeder.reader"]
exp - iat = 600s
```

Every open question this spec carried is now closed by measurement:

- **The derived username matches the declared one** — `sub` is exactly the username the blueprint
  creates, so Authentik's `update_or_create` found it rather than making a second, group-less user.
- **`roles` is non-empty**, which is the proof that pre-declaring the service account in its groups
  works. An empty claim here was the failure mode the whole design exists to avoid.
- **`aud` carries three entries and no duplicate**, so a per-client `profile` copy bound instead of
  the shared mapping emits the claim exactly once.

### Two required fields that fail the WHOLE blueprint

Both found by applying, not by reading, and each aborted the entire import — no entry applied, while
`BlueprintInstance.status` read `error` and the task log said *"Task finished processing without
errors"*. The failure is recorded on the instance, not the task; look there first.

- `redirect_uris` is **required by the provider serializer** even for `client_credentials`, which has
  no redirect. Emit `redirect_uris: []`.
- `name` is **required by the user serializer**. It is set to Authentik's own string,
  `Autogenerated user from application <app> (client credentials)`, copied from
  `post_init_client_credentials_generated` — matching it exactly is what stops the blueprint and the
  token endpoint overwriting each other's value on alternate turns.

## Worth saying before any of it is built

Every route on `interactive-map-feeder-api` is a read of **public CHMU weather data**. This work buys
an audit trail and a revocation switch, and it costs a secret on device flash, a token-refresh loop in
ESPHome YAML, the TLS migration above, and the first confidential client in the topology. That is a
reasonable trade if the goal is "every caller in this homelab has an identity" — it is a poor one if
the goal is protecting the data. Decide which it is first, because it changes whether the TLS work is
worth doing at all: without TLS, this design is theatre.

The alternative for a device that only reads public data is to leave it anonymous and put the effort
into the NetworkPolicy that already scopes what it can reach.
