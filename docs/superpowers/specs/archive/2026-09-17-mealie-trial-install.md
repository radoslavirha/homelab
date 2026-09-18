# Mealie trial install (server1)

**Status:** **Implemented and archived 2026-09-18.** Deployed on server1 as
commit `a8f8063` and verified end to end (pods, PostgreSQL tables, reissued
certificate SAN, DNS, HTTPS, `/api/app/about` → v3.27.0). Authentik login
landed in a follow-up commit the same day, which this document folds in.
The six trial questions below are still **unanswered** — they need a human in
the UI, and they remain the gate on decision 19 of the parent spec.

**Parent:** [`2026-09-13-personal-agents-platform.md`](2026-09-13-personal-agents-platform.md)
— decision 19 (a manual UI is required), decision 9 (P1, the cookbook).
Mealie was chosen over Tandoor after reading both projects' source; the
comparison and the reversal are recorded in the parent under decision 19.

**Not in this spec:** the LLM stack (Ollama, Open WebUI), any MCP tool server,
preferences, receipts, the pantry fill from shopping lists, and Authentik
login. Those wait until this trial passes.

---

## Why Mealie and not Tandoor

Both store "what's at home" as a flag, not quantities, so the pantry is not a
differentiator. Tandoor has the richer data model (food tree, substitutes,
allergen-typed properties, per-food density, USDA nutrition), but our own
agent layer filters, translates and converts anyway — and it does that for web
search results, which never live in the cookbook app at all. What is left
decides it: Mealie is one container instead of PostgreSQL plus an nginx
sidecar, ships **cs-CZ and sk-SK** translations (Tandoor has no Slovak), and
has several native iOS clients for using the shopping list in a shop.

## Questions this trial must answer

1. **Czech UI** — is `cs-CZ` complete enough to live in daily? (`sk-SK` too,
   if anyone in the household prefers Slovak.)
2. **Czech vocabulary** — does seeding foods / units / labels produce usable
   Czech entries, or is the seed data English-only?
3. **Import** — importing a Czech recipe by URL: do ingredients come out with
   the right food, unit and amount? Mealie's built-in parser is
   English-trained, so the expected answer is "poorly" — the point is to see
   *how* poorly, and whether the alternative parsers do better.
4. **Aliases** — does a food alias (`all-purpose flour` on the food `hladká
   mouka`) make an English import resolve to the Czech food?
5. **API write path** — can a recipe be created over the API with
   *already-parsed* ingredients (food + unit + amount + original text)? This
   is how our agent will write recipes, and it is the biggest integration
   risk in the whole choice.
6. **Phone** — does one of the iOS clients work against this instance, and
   what language is its own interface?

A no on 5 is the only fatal answer; everything else shapes work rather than
blocking it.

## Decisions taken for the implementer

| Item | Decision | Why |
| --- | --- | --- |
| Version | `ghcr.io/mealie-recipes/mealie:v3.27.0`, pinned | Latest release (2026-09-17). Never `latest` |
| Deployment | **Raw manifests** in `gitops/k8s-manifests/server1/mealie/` | No official Helm chart exists; the community ones on Artifact Hub trail the release (best is app v3.25.1). Mealie is a single container, so a chart buys nothing |
| Database | **PostgreSQL 17** (`postgres:17-alpine`), a one-replica StatefulSet in the same namespace | Mealie has no supported SQLite→PostgreSQL migration, while PostgreSQL→PostgreSQL is `pg_dump` and restore. `~/homelab-backups/dump-all.sh` already runs `pg_dump` (Authentik) and `mongodump`, so this database fits the existing offsite path; a SQLite file would need a new one. Our own service (people, preferences) will want a relational database too and can take a second database in this instance later |
| Namespace | `mealie` | Matches how platform apps are deployed here (headlamp, mongodb), not the `production` app namespace |
| Login | Local accounts **plus Authentik OIDC** (landed 2026-09-18) | The `authentik-blueprints` chart already supported `confidential: true` on a `kind: api` entry — the capability OpenBao uses — so no chart change was needed, only a matrix entry. Local logins stay on until an Authentik login has actually worked |
| Exposure | LAN only, `mealie.irha.cz` — **apex tier** | Named for where it is going: it goes public once the public-exposure spec's gate opens, and a rename would break phone clients and the OIDC redirect URI. Apex names cost a SAN on `server1-tls` and an individual entry in ExternalDNS `domainFilters`; neither is free the way the homelab subtree is |
| Storage | Longhorn PVCs: Mealie data 10Gi at `/app/data` (recipe images), PostgreSQL 5Gi | Images live on disk, not in the database |

**Placement is not final, and that is fine.** This PostgreSQL sits in the
`mealie` namespace because a fleet-wide PostgreSQL — with per-app credential
provisioning like the MongoDB one — is a separate decision that should not
ride on a trial. Moving to one later is a dump and a restore. Say so in the
manifest comments.

## Deliverables

All paths relative to the repo root.

1. **A new category, because none of the existing ones fit.** `apps/apps/` is
   reserved for our own apps rendered by the in-repo `iot-applications` chart
   (production + sandbox); Mealie is third-party and a singleton.
   - `gitops/argocd-manifests/roots/RootHousehold.yaml` — copy
     `roots/RootDatabases.yaml`, point `path` at
     `gitops/argocd-manifests/apps/household`, sync-wave **"4"** (after
     gateway at 2 and databases at 3, alongside RootApps). `Bootstrap.yaml`
     discovers `roots/` recursively, so nothing needs a manual apply.
   - `gitops/argocd-manifests/apps/household/Mealie.yaml` — an ApplicationSet,
     server1 only, shaped like
     `gitops/argocd-manifests/apps/databases/MongoDB.yaml`: one `list`
     generator with `cluster: server1` /
     `clusterServer: https://192.168.1.200:6443`, a single source pointing at
     the manifests path, `destination.namespace: mealie`,
     `CreateNamespace=true`, `automated: { selfHeal: true, prune: true }`.

   The category is named for what comes next (Open WebUI, Ollama, the tool
   servers), not for Mealie alone.

2. **`gitops/k8s-manifests/server1/mealie/`** — the manifests:
   - `ExternalSecret.yaml` — one field. Seed OpenBao at `server1/mealie`
     with `postgres-password`, and model the manifest on
     `gitops/k8s-manifests/server1/telegraf/ExternalSecret.telegraf.influxdb2.yaml`
     (`secretStoreRef: openbao` / `ClusterSecretStore`, `refreshInterval: 1h`,
     sync-wave `"0"`). No secret values in git.
   - `StatefulSet.postgres.yaml` + `Service.postgres.yaml` —
     `postgres:17-alpine`, one replica, Longhorn PVC 5Gi,
     `POSTGRES_DB`/`POSTGRES_USER` = `mealie`, password from the synced
     Secret. Sync-wave before Mealie so the database is up first.
   - `PVC.yaml` — Longhorn, 10Gi, mounted at `/app/data`.
   - `Deployment.yaml` — one container, `ghcr.io/mealie-recipes/mealie:v3.27.0`,
     port 9000, env:
     `BASE_URL=https://recipes.server1.homelab.irha.cz`,
     `TZ=Europe/Prague`,
     `ALLOW_SIGNUP=false`,
     `DB_ENGINE=postgres`, `POSTGRES_SERVER=mealie-postgres`,
     `POSTGRES_PORT=5432`, `POSTGRES_USER=mealie`, `POSTGRES_DB=mealie`,
     `POSTGRES_PASSWORD` from the synced Secret.
     Variable names verified against Mealie's source at tag `v3.27.0`
     (`mealie/core/settings/db_providers.py`, `settings.py`).
     **`DEFAULT_EMAIL` / `DEFAULT_PASSWORD` do not work** and must not be
     set: they are private pydantic attributes (`_DEFAULT_EMAIL`,
     `_DEFAULT_PASSWORD`), which pydantic-settings never fills from the
     environment, and `extra="allow"` means setting them fails **silently**.
     `mealie/repos/seed/init_users.py` always seeds the first admin from the
     private defaults. So the first login is
     `changeme@example.com` / `MyPassword` — see the sequence below.
     Set `strategy: Recreate`; `/app/data` is a single-writer volume.
   - `Service.yaml` → port 9000.
   - `HTTPRoute.yaml` — copy the shape of
     `gitops/k8s-manifests/server1/emqx/HTTPRoute.yaml`:
     `parentRefs: [{ name: traefik-gateway, namespace: traefik }]`, hostname
     `recipes.server1.homelab.irha.cz`, backend the Mealie Service,
     annotation `argocd.argoproj.io/sync-wave: "100"`.
     No `README.md` — no other manifest directory has one.

3. **Docs** — run the `sync-docs` skill at the end. `docs/architecture.md`'s
   component table, storage table and hostname list each gain a row. Do not
   hand-edit those and skip the skill.

## Sequence

1. Seed OpenBao (`server1/mealie`, field `postgres-password`) by hand, as with
   other seeded KV secrets: `openssl rand -base64 24`.
2. Land the manifests and the ApplicationSet on a branch. Show the diff.
   Do not commit the spec files themselves.
3. Sync in ArgoCD **once**. Do not re-trigger repeatedly — it kills in-flight
   jobs and wedges the app.
4. Wait for the pod to be `Running` and its log to show the server listening.
5. **Change the default admin password before anything else.** Mealie seeds
   `changeme@example.com` / `MyPassword` and no environment variable can
   change that (above). The instance answers on the LAN the moment the
   HTTPRoute exists, so either change the password immediately at first
   login, or land the HTTPRoute in a second commit and do the first login
   through `kubectl port-forward`. Then set your own email on that account
   and switch the interface to Czech.

## Acceptance — run these and report the output

Evidence, not assertions. Paste what each command printed.

```bash
# both pods healthy: mealie and its postgres
kubectl --context admin@server1 -n mealie get pods

# Mealie actually connected to PostgreSQL (not a silent SQLite fallback)
kubectl --context admin@server1 -n mealie exec sts/mealie-postgres -- \
  psql -U mealie -d mealie -c '\dt' | head -15

# the route answers through Traefik
curl -sSI https://recipes.server1.homelab.irha.cz/ | head -5

# the API is alive and reports its version
curl -sS https://recipes.server1.homelab.irha.cz/api/app/about | head -c 400; echo

# no errors on boot
kubectl --context admin@server1 -n mealie logs deploy/mealie --tail=40
```

Then, for question 5 — the one that actually matters — create an API token in
the UI (user profile → API tokens) and write a recipe with pre-parsed
ingredients:

```bash
TOKEN=...   # from the UI, do not paste it into git or the report
BASE=https://recipes.server1.homelab.irha.cz

# 1. create a food and a unit in Czech
curl -sS -X POST "$BASE/api/foods" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"hladká mouka"}'
curl -sS -X POST "$BASE/api/units" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"gram","abbreviation":"g"}'

# 2. create a recipe, then PATCH it with structured ingredients
#    (food id + unit id + quantity + originalText) and report whether the
#    ingredient shows up parsed in the UI, not as a plain note.
```

Report the exact request bodies that worked, because those become our tool
server's write path.

Then, in the UI, and report a short written answer plus screenshots per item:

1. Czech interface: what is still English on the main screens? Same for
   Slovak.
2. Manage Data → seed foods, units and labels: are the seeded entries Czech?
3. Import by URL:
   `https://www.toprecepty.cz/recept/18981-nadychany-hrneckovy-pernik/`
   (Czech, confirmed to publish structured recipe data) and
   `https://www.bbcgoodfood.com/recipes/white-sourdough` (English). Report
   per ingredient whether food, unit and amount are right, and try the other
   ingredient parsers Mealie offers.
4. Add the alias `all-purpose flour` to the food `hladká mouka`, re-import
   the English recipe, report whether it resolved.
5. Set a food's "on hand" flag, then check it is visible over the API
   (`GET /api/foods`) — that is how the pantry check will read it later.
6. Install one iOS client (MealieSwift, Meshi Plan, or "Mealie – Recipe &
   Meal Planner"), point it at the instance over the LAN, and report whether
   it works and what language its own interface is in.

## Constraints

- **GitOps only.** Everything except the OpenBao seeding and the UI steps
  lands in git and is applied by ArgoCD. No `kubectl apply` of app manifests.
- **No secrets in git**, and no API token in the report.
- **Nothing outside the `mealie` namespace changes**, except the
  ApplicationSet, the Root app and the docs. No network-policy edits —
  `mealie` is not under the `production` default-deny policy, and this trial
  must not need them.
- **Do not commit spec or plan files.** Show the diff and wait for approval
  before committing anything.

## Rollback

Delete the ApplicationSet and the manifests directory, let ArgoCD prune, then
remove the OpenBao key. The PVC is namespaced and goes with the namespace.
Nothing else in the fleet depends on this.

## Known follow-ups (explicitly not now)

- **Flip `ALLOW_PASSWORD_LOGIN` to `false`** once an Authentik login has
  worked, and consider `OIDC_AUTO_REDIRECT`.
- Behind a TLS-terminating proxy, gunicorn may need its forwarded-IP handling
  set, or a generated redirect URI comes back as `http://`. Not yet observed
  here — watch for it on the first login.
- Backups: add this database to `~/homelab-backups/dump-all.sh` (the script
  lives outside git and already runs `pg_dump` for Authentik), and include
  `/app/data` for the recipe images.
- A fleet-wide PostgreSQL with per-app credential provisioning, if more apps
  want one. Moving this database there is a dump and a restore.
- Filling "on hand" from ticked shopping-list items (parent decision 20).
- Public exposure, per the public-exposure spec.
