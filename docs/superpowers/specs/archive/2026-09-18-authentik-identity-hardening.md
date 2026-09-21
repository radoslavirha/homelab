# Authentik identity hardening and invitation onboarding

**Status:** Spec, ready to implement. Written 2026-09-18 after the Mealie
integration exposed the problem below; extended the same day with an onboarding
design, the measurements that settle its open questions, and a narrower fix than
the one first proposed.

**Trigger:** Mealie refuses a login unless the IdP asserts `email_verified`,
because it matches an OIDC login to an account **by email**. Authentik's
shipped `email` scope mapping returns a hardcoded `"email_verified": False`
(read from the running 2026.8.1 instance), so the check was disabled
(`OIDC_REQUIRES_EMAIL_VERIFICATION=false`, commit `cf8c839`). That was the
right call for one app on one evening. It is the wrong place to leave the
fleet, because the check was pointing at something real.

**Second trigger:** onboarding the next household member means creating a
username and a password by hand and transmitting that password over a chat app.
That does not scale past the people who already have accounts, and the password
it produces is one the operator has seen.

**Related:** [`../identity.md`](../identity.md) (the runbook this changes),
[`2026-09-13-personal-agents-platform.md`](2026-09-13-personal-agents-platform.md)
(its `identity(person_id, provider, subject)` table depends on decision 2),
[`2026-09-01-public-exposure.md`](2026-09-01-public-exposure.md) (publishes
`auth.irha.cz` before any application).

---

## The frame: three roles a field can play

Everything below follows from keeping these apart. They were conflated, which is
what produced both the vulnerability and the first draft's over-correction.

| Role | Question it answers | Which field here |
|---|---|---|
| **Identifier** | *Which account is this?* | `username` — unique, and emitted as `sub` in every token |
| **Credential** | *Can you prove it is you?* | password today; a linked social account later |
| **Attribute** | *What do we know about you?* | `email`, `name`, avatar — displayed and carried in tokens, never used to find an account |

Measured on the running instance, 2026-09-18:

```
User.username   unique: True      ← the identifier
User.email      unique: False     ← the database permits duplicates
```

An attribute used as an identifier is the defect. Email is an attribute here and
stays one.

## The problem, as believed and as measured

The first draft of this spec asserted that any user could change their own
username and email, and built a decision on it. **That is false on this
instance.** Measured 2026-09-18 by simulating Authentik's own validation policy
against a real user:

```
CHANGE USERNAME -> passing=False  ('Not allowed to change username.')
CHANGE EMAIL    -> passing=False  ('Not allowed to change email address.')
CHANGE NAME     -> passing=True
```

The `default-user-settings` prompt stage does carry `username` and `email`
fields, which is what the claim was read off. But the stage also carries a
`validation_policies` entry — the shipped `default-user-settings-authorization`
expression policy — which checks the `goauthentik.io/user/can-change-{username,email}`
group attributes and falls back to tenant settings:

```
default_user_change_username = False   (authentik's shipped default, unchanged here)
default_user_change_email    = False   (ditto)
default_user_change_name     = True
groups carrying a can-change attribute: []
```

**Presence of a field in the form is not editability.** The gate is the policy.

What remains true, and is why this spec still exists:

1. `sub_mode: user_username`, so `sub` follows the username — which is fine
   precisely *because* the username is immutable, and would stop being fine the
   day that changed.
2. Mealie looks an account up **by email** — an attribute the database does not
   require to be unique, and whose immutability rests on a tenant default rather
   than on anything this repo controls.
3. There is no way to onboard a person without the operator typing a password
   and sending it over a chat app, and no recovery flow of any kind.

Points 2 and 3 are what gets built. Point 1 is what gets verified and written
down.

### The onboarding half, equally concrete

Also measured 2026-09-18: `Source.objects.all()` returns `authentik-built-in`
and nothing else; there are zero `Invitation` and zero `InvitationStage`
objects; and the identification stage offers no enrollment flow, no recovery
flow and no sources. Every account that exists was typed in by hand.

Two shipped flows — `default-source-enrollment` and `default-source-authentication` —
**exist and are wired to nothing**. They are what the new-source form in the UI
offers by default. Adding a Google source and accepting those defaults is
therefore one click away from "anyone with a Google account has an account
here", which is why decision 3 is a contract and not a preference.

## What this spec decides

### Decision 1 — verify the protection, do not rebuild it

No prompt-stage surgery. Authentik already forbids self-service username and
email changes, by shipped default. Two things follow:

- **Do not remove the fields from `default-user-settings`.** Authentik's own
  blueprint (`/blueprints/default/flow-default-user-settings-flow.yaml`) manages
  that stage's `fields:` list with `!KeyOf` references to all four prompts. A
  local blueprint removing one would be a second writer of the same list, and
  upstream's next apply restores it — silently, with no drift visible in git.
- **The settings cannot be pinned in git either.** `authentik_tenants.tenant` is
  absent from the blueprint schema (`grep authentik_tenants /blueprints/schema.json`
  returns only `authentik_tenants.domain`), so `default_user_change_*` lives in
  the API/UI only.

So this decision is discharged by a verification check (below) that asserts the
three tenant values and the absence of any `can-change-*` group attribute, plus
a line in `docs/identity.md` saying that granting one of those attributes to a
group re-opens the hole. An upgrade that flips a default is then caught by a
command rather than by an incident.

### Decision 2 — keep `user_username` as the subject

The original spec left this open pending one question: does anything *persist*
`sub`? Grepped 2026-09-18, the answer is yes, in two places:

| System | Keys on | Persists `sub`? |
|---|---|---|
| kube-apiserver | `oidc-username-claim: sub`, prefix `oidc:` | **No.** RBAC binds groups (`headlamp.admin`), never usernames — see `gitops/k8s-manifests/server2/headlamp/ClusterRoleBinding.headlamp-oidc.yaml`. Only audit logs carry `oidc:<sub>` |
| OpenBao | `user_claim = "sub"` (`iac/modules/vault-config/oidc.tf`) | **Yes** — the entity alias name. Policies arrive via external groups, so access survives a change; the entities orphan |
| Grafana | `auth.generic_oauth` | **Yes** — its `user_auth` row is keyed on the provider's subject. Verify against the running Grafana before any change; a new subject means a new Grafana user and an email collision with the old one |
| Mealie | by email today, by `preferred_username` after decision 4 | Persists whichever it matched on |

So "changing `sub_mode` costs nothing but a re-login" was wrong. It costs
orphaned OpenBao entities and a Grafana account collision.

**Decided: keep `user_username`, frozen by decision 1.** The personal-agents
platform should still key its `identity(person_id, provider, subject)` rows on
a UUID subject, which means a per-provider `sub_mode` and a chart change — that
belongs to that spec, not this one.

### Decision 3 — the source contract

No social source is wired by this spec. What it writes down instead is what any
future source **must** satisfy, because the UI defaults the other way:

- **`enrollment_flow` unset.** With an enrollment flow, anyone holding an
  account at that provider can create an account here. The group gate
  (`<app>.<role>`) still stops them reaching any application, but an unbounded
  account directory is not worth having.
- **`user_matching_mode: identifier`**, never `email_link` or `username_link`.
  (The running instance offers `identifier | email_link | email_deny |
  username_link | username_deny`.) Both `_link` modes make an attribute into an
  identifier again, by the back door: a source that asserts an address links to
  whoever holds it, and the address is not even unique.
- **Linking happens from a signed-in user's settings page**, and nowhere else.
  That path is `Action.LINK` → `handle_existing_link` in
  `authentik/core/sources/flow_manager.py`, which is core, not enterprise.

Apple is the specific reason the second rule matters: it issues per-app private
relay addresses that the user can disable, so an Apple-supplied email is neither
stable nor meaningful. Apple also costs a paid developer account and a client
secret that is a JWT expiring at most every six months, forever.

**What the household gets from this:** password, Google, GitHub and anything
later all resolve to **one Authentik user** — one `User` row with N
`UserSourceConnection` rows. Applications never learn which provider was used;
they see the same `sub`, the same `roles`, the same account. Same-user-across-
providers is a property of linking at the IdP, and it holds only while nothing
auto-creates a second user, which is what the three rules above prevent.

### Decision 4 — Mealie stops looking accounts up by email

Set `OIDC_USER_CLAIM: preferred_username` on Mealie's Deployment. With decision
1's finding, this is defence in depth rather than a fix for a live hole — and it
is still worth doing, because matching by email depends on three things staying
true (a tenant default, the absence of a group attribute, and a column the
database does not constrain), while matching by username depends on none of
them. The lookup key becomes the identifier: unique, and immutable by default.

Read at `v3.27.0` before deciding, and all four hold:

- `mealie/core/settings/settings.py` — `OIDC_USER_CLAIM: str = "email"` is a
  default, and Mealie's own docs name `preferred_username` as the alternative.
- `auth_provider.try_get_user` — *"first trying username, then trying email"*.
  Passing `preferred_username` matches by username.
- `openid_provider.authenticate` creates OIDC accounts with
  `username = claims.get("preferred_username", …)`, so accounts created before
  this change **already carry the Authentik username**. The switch matches the
  same row; no duplicate, no migration.
- Authentik needs no change: the local `homelab profile` scope mapping already
  emits `"preferred_username": request.user.username`.

Two consequences to keep straight:

- **`OIDC_REQUIRES_EMAIL_VERIFICATION=false` stays, and becomes honest.** That
  flag exists to guard email-based matching — Mealie's own comment says so. Once
  nothing matches by email, the guard has nothing to guard. **Do not** add a
  local `email` scope mapping asserting `email_verified: true`; with
  self-asserted addresses that would be a fabricated claim, emitted fleet-wide,
  to satisfy a check that no longer applies. That was the first draft's plan and
  it is withdrawn.
- **Email is still required and must be non-empty.** Mealie's `required_claims`
  is `{OIDC_NAME_CLAIM, "email", OIDC_USER_CLAIM}`. Every user needs an email
  set — they simply set it themselves.

**Standing rule, sibling to the source contract:** no application added to this
fleet may match accounts by email. The day one does, an editable non-unique
attribute is load-bearing identity again. This is a review rule, not a
mechanism, and it belongs in `docs/identity.md` where applications are added.

### Decision 5 — onboarding is invitation-only, and the operator never sees a password

One enrollment flow, reachable only with a token:

```
homelab-enrollment      designation: enrollment, authentication: require_unauthenticated

10  invitation stage    continue_flow_without_invitation: FALSE    ← the gate
20  prompt stage        username, name, email, password, password_repeat
        validation_policies: default-password-change-password-policy (ships with authentik)
30  user_write stage    create_users_group: household, user_path: users/household
40  user_login stage    the invitee lands signed in
```

**Order 10 is the security argument.** With `continue_flow_without_invitation:
false`, the flow's URL is safe to be internet-reachable: no token means
`Invalid invite/invite not found`, no account, nothing disclosed. The login page
gets no registration link either — the identification stage's `enrollment_flow`
stays `None`, as it is today.

**Order 20 renders everything except the identifier.** Read from
`authentik/stages/invitation/stage.py` on the running instance:

```python
always_merger.merge(context, self.executor.plan.context.get(PLAN_CONTEXT_PROMPT, {}))
always_merger.merge(context, invite.fixed_data)
self.executor.plan.context[PLAN_CONTEXT_PROMPT] = context
```

`fixed_data` lands **in `prompt_data`**, which `user_write` later consumes — and
a rendered prompt field overwrites it with whatever the invitee typed. So the
invitation carries `username`, the prompt must not render `username`, and the
invitee owns everything else about their own profile.

**Per person, two UI actions and a password the operator never sees:**

1. Directory → Invitations → Create. `single_use: true`, expiry ~7 days, flow
   `homelab-enrollment`, and no custom attributes (or `fixed_data: {username: jana}`
   to prefill a suggestion).
2. Send `https://auth.irha.cz/if/flow/homelab-enrollment/?itoken=<uuid>` over
   whatever chat is already in use.
3. Once they are in, add them to the application role groups they need — the
   same UI work every membership is today.

**Invitations are not in git.** They carry a bearer token; they are user data,
like memberships.

`household` grants nothing — no application binding, no ladder parentage. It
exists so "who came in by invitation" is one query, and so a future
household-wide application has one object to bind.

**Two quirks, documented rather than designed around:**

- A `single_use` invitation is **deleted at order 10**, before the invitee
  reaches the prompt. Abandon halfway and the invite is burned; issue another.
- The token rides in a URL, so it lands in Authentik's logs and in the chat
  history. Single use plus a short expiry is what bounds that.

**Deliberately not built:** folding step 3 into step 1. `fixed_data` merges into
`prompt_data`, while `user_write` reads groups from the *root* context
(`PLAN_CONTEXT_GROUPS`), so granting roles from an invitation needs an
expression policy to resolve names into Group objects. Real code, not a field.

### Decision 6 — recovery is an admin-minted link, until SMTP exists

No SMTP is configured **yet** — see the next section. Until it is:

```
homelab-recovery        designation: recovery, authentication: require_unauthenticated

10  prompt stage        password, password_repeat (same validation policy)
20  user_write stage
```

Wire it to **`brand.flow_recovery`** so the admin user page's *Create recovery
link* works. Leave the identification stage's own `recovery_flow` **empty**, so
the login page shows no "Forgot password?". The operator mints a link and sends
it over the same channel as the invitation.

- **Cost:** the operator is the recovery path for 10–50 people.
- **Benefit:** no public reset surface, and no username enumeration via a reset
  form on a page that is about to be published.

Measured need, same day: a failed password login at 14:38 left `kubectl exec
… ak changepassword` as the only reset path, because no recovery flow exists.
That is survivable for an operator with a kubeconfig and not for anyone else.

## SMTP: deferred, not rejected

Nothing here depends on email being an identifier, so adding mail later is
additive. When it lands it buys three things, in this order of value:

1. **Self-service recovery** — an email stage in `homelab-recovery`, replacing
   the admin-minted link. This is the one that stops scaling first.
2. **Self-service email change with confirmation** — the user proves an address
   before it takes effect, so the attribute becomes trustworthy rather than
   merely owned.
3. **A genuine `email_verified` claim** — true because a link was clicked. Only
   then may an application be allowed to match on email again, and even then the
   standing rule in decision 4 should be revisited deliberately rather than
   assumed lifted.

What it needs, recorded so the estimate is not re-derived: a relay account or a
sender on `irha.cz` with SPF/DKIM/DMARC (the zone deliberately holds almost
nothing today), one secret in OpenBao, `AUTHENTIK_EMAIL__*` env, and one email
stage per flow that uses it.

## The chart extension

`gitops/helm-charts/authentik-blueprints/templates/configmap.yaml` renders
scopemapping, group, oauth2provider, proxyprovider, application, policybinding,
user and outpost today, all driven by the `applications` matrix. Onboarding is
not per-application, so it gets its own top-level values key, rendered into the
same ConfigMap and emitted **before** the applications block so `!KeyOf`
references resolve — the ordering constraint devices already live under.

```yaml
onboarding:
  enabled: true
  userPath: users/household
  group: household
```

It renders into a **second data key**, `homelab-onboarding.yaml`, beside the
existing `homelab-applications.yaml`. Authentik discovers every `.yaml` key as
its own blueprint file, so each becomes its own `BlueprintInstance`: a malformed
onboarding entry cannot take the applications graph down with it. The worker
already mounts the whole ConfigMap (`blueprints.configMaps: [authentik-blueprints]`),
so no Authentik values change is needed. `!KeyOf` does not cross blueprint
files — onboarding references nothing in the applications graph, so that costs
nothing.

New models for the chart: `authentik_flows.flow`, `authentik_flows.flowstagebinding`,
`authentik_stages_prompt.prompt` and `.promptstage`,
`authentik_stages_invitation.invitationstage`, `authentik_stages_user_write.userwritestage`,
`authentik_stages_user_login.userloginstage`, `authentik_core.group`, plus an
`authentik_brands.brand` update for `flow_recovery`.

Authentik ships this exact shape as `/blueprints/example/flows-invitation-enrollment.yaml`
(inert — `blueprints.goauthentik.io/instantiate: "false"`). The chart follows it,
including `evaluate_on_plan: true` / `re_evaluate_policies: true` on the
invitation stage's binding.

Both existing rules apply unchanged. **Blueprints do not prune**: dropping
`username` from `userSettings.fields` leaves the Prompt object behind — it stops
being *bound*, which is what actually matters. And a malformed entry fails the
**whole** blueprint silently, so `BlueprintInstance.status` is the thing to
read, never the task log.

## Why social-at-enrollment is not in this spec

The wanted shape — one invitation page where "choose a password" and "sign in
with Google" are equal, both gated by the same token — **is not buildable on
this instance.** Measured 2026-09-18:

```
only writer of the flow-context carry-over:
  /authentik/enterprise/stages/source/stage.py   SESSION_KEY_SOURCE_FLOW_CONTEXT
                                                 SESSION_KEY_OVERRIDE_FLOW_TOKEN
License.objects.count() == 0        LicenseKey.get_total().status() == "unlicensed"
```

The **Source Stage is an enterprise feature**, and it is the only thing in
2026.8.1 that carries an in-progress flow's context across an OAuth round-trip.
A source button on an identification stage is a plain link out: the provider
returns into the *source's own* enrollment flow with fresh context, so an
invitation token never survives the trip and an invitation stage there would
deny every social enrollment, including the legitimate ones.

Therefore social identities are **linked after the fact** by a signed-in user,
per decision 3. The alternative — pre-authorising an email address so social can
be the first credential — was considered and rejected: it needs a custom
expression policy plus a property mapping that drops unverified emails, it
cannot work for Apple at all, and it makes an attribute into an identifier
again, which is the defect this spec exists to remove.

## Out of scope

- **MFA.** The stage is bound in the authentication flow at order 30 with
  `not_configured_action: skip`, so it is opt-in and nobody has enrolled.
- **Login-surface hardening.** `show_matched_user: True` today — the login page
  confirms which usernames exist. There is no reputation or lockout policy
  anywhere, so password spraying is unthrottled.
- **Public exposure itself**, which is the public-exposure spec's gate.
- **Per-application `sub_mode`**, which belongs to the personal-agents platform.

The first two become live risks the day `auth.irha.cz` is published — and the
public-exposure spec publishes it *first*, before any application. They are the
next spec, not this one.

## Implementation order

1. **Decision 4.** One env var on Mealie's Deployment, independent of everything
   else. Verify a login still lands in the same Mealie account.
2. **The enrollment flow.** Chart learns the onboarding blueprint category:
   values key, `_onboarding.tpl`, second ConfigMap data key, helm-unittest
   coverage.
3. **The recovery flow and the brand wiring**, in the same template.
4. **Deploy and verify on the cluster**, then run one real invitation end to end
   for a household member rather than the operator.
5. **Docs.** `docs/identity.md` gains the onboarding runbook, the source
   contract, the no-matching-by-email rule, and the tenant-settings check.

## Verification

Evidence, not assertions — each of these is a thing to run and paste:

```bash
# 1. Decision 4: Mealie matched the SAME account, by username
kubectl --context admin@server1 -n mealie logs deploy/mealie | grep -i oidc | tail

# 2. Decision 1: self-service identity changes are still refused
kubectl --context admin@server3 -n authentik exec deploy/authentik-worker -- ak shell -c "
from authentik.tenants.models import Tenant
from authentik.core.models import Group
t = Tenant.objects.first()
print('username', t.default_user_change_username, '| email', t.default_user_change_email)
print('group overrides:', [g.name for g in Group.objects.exclude(attributes={})
                           if any('can-change' in str(k) for k in g.attributes)])"
# expect: username False | email False | group overrides: []

# 3. The enrollment flow denies without a token
curl -s -o /dev/null -w '%{http_code}\n' https://auth.irha.cz/if/flow/homelab-enrollment/

# 4. Both blueprints applied — the INSTANCE, not the task log
kubectl --context admin@server3 -n authentik get blueprintinstance -o wide

# 5. Recovery reachable by the admin, not by the public
kubectl --context admin@server3 -n authentik exec deploy/authentik-worker -- ak shell -c "
from authentik.brands.models import Brand
from authentik.stages.identification.models import IdentificationStage
print('brand recovery:', Brand.objects.get(domain='authentik-default').flow_recovery)
s = IdentificationStage.objects.get(name='default-authentication-identification')
print('login page recovery:', s.recovery_flow, '| enrollment:', s.enrollment_flow,
      '| sources:', [x.slug for x in s.sources.all()])"
# expect: brand recovery set; login page recovery None, enrollment None, sources []

# 6. No fabricated claim was added anywhere
kubectl --context admin@server3 -n authentik exec deploy/authentik-worker -- ak shell -c "
from authentik.providers.oauth2.models import ScopeMapping
for m in ScopeMapping.objects.filter(scope_name='email'):
    print(m.name, '|', 'email_verified' in m.expression)"
```

Also by hand: run one invitation to completion as a real household member, and
confirm the operator never learned their password.

## Risks

- **The standing rule is a review rule.** Nothing mechanically stops a future
  application from being configured to match on email. When one is added, that
  is the question to ask first.
- **Email is self-asserted and not unique.** Two accounts may hold one address.
  Harmless while nothing matches on it; it is the reason the rule above exists.
- **The operator is the recovery path.** Decision 6 trades self-service for no
  SMTP and no public reset surface. At 10–50 people that is a few messages a
  year; SMTP is the documented upgrade, not a redesign.
- **Blueprints do not prune.** Removing an onboarding entry from values stops
  managing the object; it does not delete it. Removal is the same two-commit
  `state: absent` dance the applications matrix documents.
- **The protection is upstream's default, not ours.** `default_user_change_*`
  cannot be pinned in git, so an authentik upgrade that changes a default, or a
  `can-change-*` attribute added to a group, silently re-opens what decision 1
  relies on. Verification check 2 is the only thing that catches it.
- **A burned invitation.** `single_use` deletes at the gate, not at completion,
  so an abandoned enrollment costs a new invitation.
- **Locking yourself out.** Land flow changes only while you hold a working
  admin session: a malformed blueprint plus no password plus no recovery flow
  leaves `kubectl exec` as the only way back.
