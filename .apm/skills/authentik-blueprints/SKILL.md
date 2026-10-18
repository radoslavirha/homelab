---
name: authentik-blueprints
description: "Add, change or remove an Authentik application, role, client, device or proxy-guarded UI through the generated blueprint matrix, then confirm Authentik actually applied it. Use when an app needs SSO or a new role, a Postman-style client or a machine needs a token, a UI needs forward-auth, a role is renamed or dropped, or a blueprint change does not seem to have landed."
argument-hint: "What to change, e.g. 'add mealie admin role' or 'remove the old grafana-server2 app'"
---

# authentik-blueprints

Every Authentik application, provider, role group, policy binding and proxy outpost is **generated**
by the `authentik-blueprints` chart from one matrix:
`gitops/helm-values/server3/authentik-blueprints.yaml`. Never click these together in the UI. Model,
naming and token claims: `docs/identity.md`.

## Prerequisites

- CLIs: `helm`, `yq`, `jq`, `kubectl`, `git`.
- `KUBECONFIG` with server3 in it — commands use `--context admin@server3` (AGENTS.md § Access).
- An Authentik admin session in the UI, for the steps that are deliberately not in git (group
  membership, reading a generated client secret).

## Pick the change

| Change | Section |
|--------|---------|
| New application, or edit an existing one | Add or edit |
| New, renamed or removed role | Add or edit (rename = create + orphan) |
| A human-driven tool calling several APIs (`kind: client`) | Add or edit, plus Clients and devices |
| A machine needing a token (`kind: device`) | Add or edit, plus Clients and devices |
| A UI with no login of its own (`kind: proxy`) | Add or edit, plus Proxies |
| Remove an application | Remove — two commits |

## Add or edit

Copy this checklist and tick it off:

```
Blueprint change:
- [ ] 1. Matrix entry edited
- [ ] 2. Renders cleanly (helm template)
- [ ] 3. Hardening/onboarding touched? Importer.validate() says VALID: True
- [ ] 4. Diff shown to the operator, committed, pushed
- [ ] 5. authentik-server3 hard-refreshed and synced once
- [ ] 6. Applied: last_applied moved AND the objects exist
- [ ] 7. Members added to the new groups in the UI (not in git)
```

**1. Edit the matrix.** An entry has `name`, `title`, `hostPrefix` or `host`, optional `basePath`,
`roles`, and one `environments` entry per cluster + environment (`{ cluster: server1, stage: sandbox }`,
plus `{ stage: local }` for a developer machine). Worked example: `docs/identity.md` § Adding an
application. Roles are a ladder, most-privileged first:

```yaml
roles:
  - name: admin
    inherits: editor
  - name: editor
    inherits: reader
  - name: reader
```

A bare string (`- reader`) is a role with no parent. **No application may match accounts by email** —
match on `preferred_username`.

**2. Render.** The chart `fail`s on a dangling `inherits`, a cycle, a self-inheriting role, a duplicate
name, or an application with no roles (an Application with no binding is readable by every user):

```bash
helm template ab gitops/helm-charts/authentik-blueprints \
  -f gitops/helm-values/server3/authentik-blueprints.yaml > /tmp/ab.yaml && echo RENDER-OK
```

On a failure, read the `fail` message, fix the matrix, render again. Do not push until it renders.

**3. Dry-run hardening or onboarding.** `helm unittest` cannot see a bad model path, a rejected field
or an unresolved `!Find`. If the change touches `hardening` or `onboarding`, run the importer dry-run in
`docs/identity.md` § The login surface (subsection "After every Authentik upgrade") and require
`VALID: True` with no warnings. Two lines decide whether anyone can log in at all: the order-15 deny
stage must keep ≥ 1 policy bound, and the MFA chooser must not be empty.

**5. Deploy.** Pushing is not deploying. Hard refresh, then sync **once**. `authentik-server3` is
multi-source (the Authentik chart, then three sources from this repo), so the sync names one revision
per source: the chart's pinned version, then your commit. With `"revision":"HEAD"` only the first
attempt runs at HEAD; the retries fall back to the last-synced commits and can "succeed" without your
change (AGENTS.md § Commands).

```bash
kubectl --context admin@server3 -n argocd annotate application authentik-server3 \
  argocd.argoproj.io/refresh=hard --overwrite
R=$(git rev-parse origin/main)
REVS=$(kubectl --context admin@server3 -n argocd get application authentik-server3 -o json \
  | jq -c --arg r "$R" '[.spec.sources[]
      | if .repoURL == "https://github.com/radoslavirha/homelab" then $r else .targetRevision end]')
kubectl --context admin@server3 -n argocd patch application authentik-server3 --type merge \
  -p "{\"operation\":{\"sync\":{\"revisions\":$REVS}}}"
```

Then `status.sync.revisions` must list the same commit for every homelab source.

**6. Confirm it applied — this is a loop.** Authentik applies blueprints on a cron
(`blueprints_discovery` at `57 * * * *`) and only when the file hash changed, so the wait is up to an
hour. The kubelet takes up to a minute to propagate the ConfigMap, so a discovery firing right after the
sync can hash the OLD file and do nothing. The import is one transaction (~5 min for this matrix):
nothing appears until it commits. To skip the wait, enqueue discovery — never `ak apply_blueprint`,
which runs a second importer and contends with the scheduled one:

```bash
kubectl --context admin@server3 -n authentik exec deploy/authentik-worker -- ak shell -c \
  "from authentik.blueprints.v1.tasks import blueprints_discovery; blueprints_discovery.send()"
```

Then check, and repeat the check until it is true — the task log claims success either way:

```bash
kubectl --context admin@server3 -n authentik exec deploy/authentik-worker -- ak shell -c "
from authentik.blueprints.models import BlueprintInstance
for b in BlueprintInstance.objects.all(): print(b.name, b.status, b.last_applied)"
```

`last_applied` must be newer than your sync, and the objects you added must exist (query them, or look
in the UI). `queued` in the task table is not a failure; it once took ~10 minutes. `status: error` right
after a manual apply is lock contention — wait for the next scheduled run before diagnosing.

**Renaming a role is a create plus an orphan:** the new group appears, the old one keeps its members
and binding. Delete the old group in the UI and re-add its members. The same holds for removing a role.

## Clients and devices

- **client** (`kind: client` — Postman): `accesses: [<app>, …]` and `redirectUris:` instead of a host.
  Its token's `aud` names every target; its `roles` claim comes from groups the human already holds.
- **device** (`kind: device` — a machine): `accesses: [{ app: <app>, role: <role> }]`, no redirect
  URIs. The chart declares its service account in the target's role group. Its `client_secret` is
  generated by Authentik — read it from the provider page in the UI and put it in the device; it is
  deliberately not in git.
- Either renders ONE application across every environment it lists: one login, one token, the union of
  the holder's roles. Each target API needs one trusted-issuer row for it — in this repo, under
  `auth.IDP.trustedIssuers` in `gitops/helm-values/server1/apps/<api>/values-<env>.yaml`.

Details: `docs/identity.md` § Client-only applications.

## Proxies

`kind: proxy` renders a `forward_single` proxy provider for one host plus one outpost per cluster
(`homelab-proxy-<cluster>`). Authentik owns every OAuth2 field on it, so the entry carries no
`basePath`, `redirectPath`, `redirectUris`, `confidential` or `{ stage: local }`.

```
Proxy extras:
- [ ] Once per CLUSTER: outpost objects in gitops/k8s-manifests/<cluster>/traefik/
- [ ] Once per CLUSTER: outpost token copied into OpenBao (UI: Outposts → View Deployment Info)
- [ ] Per UI: Middleware.authentik.yaml in the UI's own namespace
- [ ] Per UI: ExtensionRef filter on its HTTPRoute
- [ ] Per UI: a second route rule sending /outpost.goauthentik.io/ to the outpost
```

Without the last rule the login callback is forward-authed too and the login never completes.
Verification commands: `docs/identity.md` § Proxies — UIs with no login of their own.

## Remove — two commits

Blueprints do not prune: deleting an entry stops *managing* its objects, it does not delete them. On
2026-09-13 that left six providers with live credentials behind.

```
Removal:
- [ ] Commit 1: set `state: absent` on the entry, change NOTHING else (keep roles + environments —
      they name what to delete; the chart refuses an absent entry without them)
- [ ] Deploy and confirm per Add or edit, step 6 — the objects are GONE
- [ ] Commit 2: delete the entry from the matrix (a spent deletion entry is a no-op, so this can wait)
```
