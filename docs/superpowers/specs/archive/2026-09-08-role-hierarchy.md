# Role hierarchy — making `admin` imply `reader`

**Status: built and synced 2026-09-08.** Commit `1553740`; ArgoCD synced `authentik-server3` and the
rendered ConfigMap in the cluster carries the parentage. Whether Authentik's worker applied the
blueprint was not confirmed from this machine — check **Directory → Groups** for a `-editor` group.
Two manual steps remain — see *Migration*.

The fact this rests on is no longer "unverified": it is read straight out of the deployed version's
source, quoted under *Why the direction is settled*.

**Trigger:** `iot-miniservers` now authorizes. `@RequireRoles('miot-bridge.admin')` guards
`miot-bridge-api`'s `/command`, verified live 2026-09-08 — no credential `401`, a verified caller
without the role `403`, with it through to the handler. Applying the same decorator as a *class-level
floor* is what runs into the problem below.

**Related:** [`2026-09-04-authentik-tenancy-topology.md`](./2026-09-04-authentik-tenancy-topology.md),
which owns the object model and whose *Devices* section this does not touch.

## What happens today

Roles are flat. A token carries exactly the groups the user is in, stripped and re-prefixed:

```json
"sub": "claude",  "roles": ["qr-manager.admin", "qr-manager.reader"]
```

`claude` holds both **because `claude` is in both groups**. Membership of `qr-manager-local-admin`
grants nothing toward `qr-manager.reader`. Every user must be added to every group they need, and the
list grows with each role and each environment.

## Why this now costs something

`@RequireRoles` composes as *"or" within one decorator, "and" between them* — a method can only narrow
what its class allowed, which is the safe direction and is enforced by the shape of the stored value.
That makes the natural pattern a floor plus exceptions:

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

With flat roles, a user holding **only** `admin` is refused there: they satisfy the admin requirement
and not the reader one. Fail-closed, so nothing is unsafe — but the floor pattern is unusable, and the
alternative is repeating every role on every route.

**The fix belongs here, not in the APIs.** If `@RequireRoles('reader')` silently accepted an admin
token, the token would stop describing what its holder can do: an auditor reading it would be wrong,
and every future consumer — a second API, EMQX, a script — would need to carry the same ordering table
and agree with it. Issuing the roles correctly keeps the claim the whole truth and leaves each
consumer a set-membership test.

## What Authentik gives us

Groups are hierarchical. From `core/models.py`:

```python
class Group(SerializerModel, AttributesMixin):
    """Group model which supports a hierarchy and has attributes"""
    name = models.TextField(unique=True)
    parents = models.ManyToManyField("Group", through="GroupParentageNode", related_name="children")
```

and from the docs:

> `request.user.all_groups()` — "all groups a user belongs to, **including parent groups**"
>
> "Members of child groups are considered **effective members of the parent**."

The blueprint's `roles` mapping already calls `all_groups()`, so **nothing in the mapping changes**:
the parent groups carry the same `<client_id>-` prefix its filter looks for, get stripped and
re-prefixed identically, and simply appear in the claim.

Membership flows **upward**, so the containment is the inverse of how the privilege ladder is usually
drawn:

```
qr-manager-local-reader          parent   — least privilege
└── qr-manager-local-editor
    └── qr-manager-local-admin   child    — most privilege
```

A user in `-admin` alone would then get:

```json
"roles": ["qr-manager.admin", "qr-manager.editor", "qr-manager.reader"]
```

**Do not confuse this with `authentik_rbac.Role`.** That model governs who may administer Authentik
itself and never reaches an application's token. The docs sentence "roles support inheritance through
group hierarchy" is about *those* roles; the one this design rests on is the plain
group-membership sentence above. We use no `authentik_rbac.Role` objects at all.

## Why the direction is settled

The design collapses if `all_groups()` walks toward children rather than parents. It does not. From
`authentik/core/models.py` at **`version/2026.8.1`** — the tag pinned in
[`Authentik.yaml`](../../../../gitops/argocd-manifests/server3/apps/identity/Authentik.yaml):

```python
def all_groups(self) -> QuerySet[Group]:
    """Recursively get all groups this user is a member of."""
    return self.groups.all().with_ancestors()

def with_ancestors(self):
    pks = self.values_list("pk", flat=True)
    return Group.objects.filter(Q(pk__in=pks) | Q(descendant_nodes__descendant__in=pks)).distinct()
```

Direct groups **plus their ancestors**. So `-reader` is the parent and `-admin` the child, which is
the orientation drawn above.

The second open question — whether the policy binding still admits an `-admin`-only member — has the
same answer, and for the same reason:

```python
# authentik/policies/models.py
if self.group:
    return PolicyResult(self.group.is_member(request.user))

# authentik/core/models.py
def is_member(self, user: User) -> bool:
    """Recursively check if `user` is member of us, or any parent."""
    return user.all_groups().filter(group_uuid=self.group_uuid).exists()
```

Bindings follow parentage. The chart binds every role group explicitly anyway, so this is a
confirmation, not a dependency.

**Where the ancestry actually lives:** `GroupParentageNode` is an edge table, and the transitive
closure is the materialized view `authentik_core_groupancestry`, refreshed by a Postgres trigger on
every insert, update and delete of an edge. Nothing to configure — but if a claim ever looks stale
after a parentage change, that view, not the traversal, is the thing to suspect.

## The chart change — as built

`roles` was a flat list (`[admin, reader]`), one group per entry, no parentage. Two ways to express a
ladder:

| | |
| --- | --- |
| **Ordered list, each a child of the next** | Concise, and implicit. Someone adding a role in the middle silently re-parents two others — a privilege change that reads as a formatting change. |
| **Explicit `inherits:`** | Verbose, and says what it means. |

**The explicit form**, written most-privileged first:

```yaml
roles:
  - name: admin
    inherits: editor
  - name: editor
    inherits: reader
  - name: reader
```

A bare string is still accepted and means a role with no parent, so a future single-rung application
needs no ceremony. Four things the template does beyond rendering `parents`:

**1. Parents are emitted before children.** Not cosmetic — `!KeyOf` resolves only against entries that
already have a model instance:

```python
for _entry in blueprint.iter_entries():
    if _entry.id == self.id_from and _entry._state.instance:
        return _entry._state.instance.pk
raise EntryInvalidError.from_entry("KeyOf: failed to find entry with `id` ... and a model instance")
```

Rendering the ladder in declaration order puts `admin` first, pointing `!KeyOf` at an `editor` that
has not been applied yet, and the entry fails. The template emits the parentless roles, then whatever
became emittable, `N` passes deep.

**2. `parents` is emitted on every role, `parents: []` included.** A blueprint leaves a field it does
not mention exactly as it found it. Without the empty list, deleting an `inherits:` line from values
would leave the parentage — and the privilege — in place on the instance forever.

**3. Cycles `fail` the render.** `GroupSerializer.parents` is a plain writable
`PrimaryKeyRelatedField(many=True)` with no cycle validation, so `a inherits b inherits a` is
something Authentik would accept. Anything unordered after `N` passes is a cycle, and the template
names the roles it could not place. Self-inheritance, duplicate role names and a role entry with no
`name` fail too.

**4. Binding `order` moved from `identifiers` to `attrs`.** It was part of the binding's identity and
came from the list index, so inserting `editor` in the middle shifted `reader` from `1` to `2` — which
does not update `reader`'s binding, it creates a **second** one and orphans the first. Keyed on
`target` + `group`, the existing rows are matched and updated instead. Pre-existing wart; the ladder
is what made it certain to fire.

## Migration

**Every application got the same three rungs** — `admin` → `editor` → `reader` — rather than a ladder
only where routes exist today. One shape everywhere is worth more than four bespoke ones, and the rungs
below the used one cost a group per environment and nothing else.

That renamed `homelab-dashboard`'s `viewer` to `reader`, and **blueprints do not prune**. The
`homelab-dashboard-*-viewer` groups and their bindings survive the sync, so a member of one keeps both
access to the application and a `homelab-dashboard.viewer` claim. Delete them by hand in the Authentik
UI after the sync, and re-add their members to `-reader`. Any `@RequireRoles('homelab-dashboard.viewer')`
in a consumer moves to `.reader` at the same time.

Second manual step, and the one that actually exercises the ladder: **users currently hold redundant
memberships.** `claude` is in both `qr-manager-*-admin` and `qr-manager-*-reader`, so the claim looks
identical whether parentage works or not. Drop the `-reader` memberships, then log in and read the
token — `iot-miniservers` has a Playwright script that intercepts the token response and decodes it.
Expected:

```json
"roles": ["qr-manager.admin", "qr-manager.editor", "qr-manager.reader"]
```

Blueprints manage no memberships, so nothing in git does either of these.

## What this does not change

- **The APIs.** `@RequireRoles` stays an exact set-membership test with no hierarchy and no wildcards.
  That is the point.
- **The `roles` mapping.** It already calls `all_groups()`.
- **Group naming.** Still `<client_id>-<role>`, still globally unique, still stripped to
  `<app>.<role>` in the claim.
- **Devices.** A device's authorization is its `aud`, not a role claim — see the topology spec.

## Consequences worth stating

- **Removing a role from a user gets subtler.** Dropping someone from `-admin` leaves them whatever
  the parents grant. That is the intent, but "remove their access" now means removing the *lowest*
  membership they hold, not the highest.
- **Revocation latency is unchanged and still bounded by the access token lifetime** — 30 minutes for
  the SPA providers. A demotion is not visible until the token renews.
- **The ladder is per application.** `qr-manager.admin` implies nothing about `miot-bridge`, because
  the groups are per `client_id` and the mapping filters to the issuing one.
- **Three rungs exist everywhere, most of them unused.** 51 groups instead of 17. `editor` has no
  routes on any application yet, and `interactive-map-feeder` has no write surface at all. The cost is
  rows in a table; the benefit is that the first write route on any of them is a values change and not
  a re-issue of everyone's groups.
