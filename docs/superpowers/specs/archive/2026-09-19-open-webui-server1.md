# Open WebUI on server1

**Status:** **IMPLEMENTED, MERGED and archived 2026-09-21.** Written 2026-09-19; landed as
`a9054fd` (the assistant on server1, with pgvector) and `4900a07` (Authentik-only login,
Ollama engine wired), merged in PR #7. Verified running 2026-09-21. The live reference is
now `docs/architecture.md:49-50`, not this file — read this one only for the reasoning.

**Parent:** [`2026-09-13-personal-agents-platform.md`](../2026-09-13-personal-agents-platform.md)
— decision 6 (Open WebUI is the chat UI and MCP client), decision 4 (reuse
Authentik), decision 8 (Automations may close the scheduling gap), decision 12
(designed for internet exposure later).

**Sibling, buildable in parallel:**
[`2026-09-19-ollama-server2.md`](2026-09-19-ollama-server2.md). The two specs
share one seam and touch **no file in common**. Either can land first.

**Not in this spec:** any MCP tool server, the Mealie integration, per-user
Mealie tokens, preferences, the alias sweep tool, RAG content, and scheduled
automations. This spec delivers a logged-in chat UI with a database that can
hold vectors when something eventually puts them there.

---

## Why this exists

`assistant.irha.cz` is the household's general-purpose LLM front end: a place to
experiment, and later the host for automations and MCP tools. Its value is not
recipes — Mealie already does recipes through its own AI provider, on Claude,
with no infrastructure. Its value is everything that is *not* a single app's
built-in feature, and a place to learn how the pieces connect.

**It does not depend on the Ollama spec.** Open WebUI is fully deployable and
usable against a cloud model connection — the same Claude key already working
in Mealie. Adding an Ollama connection afterwards is filling in a form in
Settings, not a deployment step. Build and verify this without waiting.

## The seam with the Ollama spec

The only thing consumed from the sibling spec, and only at the very end:

| | Value |
| --- | --- |
| Connection type | Ollama, or OpenAI-compatible at `/v1` |
| Base URL | `https://ollama.server2.homelab.irha.cz` |
| API key | any non-empty placeholder string — Ollama ignores it, but the form requires one |

Cross-cluster over the LAN: Open WebUI runs on server1 (`192.168.1.200`),
Ollama on server2 (`192.168.1.201`). The sibling spec pins an `ipAllowList` to
this cluster's node address, so the call works from a pod here and from nowhere
else. If the connection test fails, check that allowlist before suspecting
anything in this spec.

## Decisions taken for the implementer

| Item | Decision | Why |
| --- | --- | --- |
| Cluster | **server1**, namespace `open-webui` | Parent decision 3: server2 is the LLM engine, everything else is here. server1 holds the datastores and the Longhorn capacity |
| Deployment | **Raw manifests** in `gitops/k8s-manifests/server1/open-webui/` | Consistent with Mealie. The community charts add indirection over what is a single container plus a database |
| Version | **`ghcr.io/open-webui/open-webui:v0.11.3`**, pinned (released 2026-08-31) | Never `latest`. Record the chosen tag here when it lands. Renovate visibility for raw manifests is handled by the sibling spec's `renovate.json5` edit — do not duplicate it |
| Exposure | **`assistant.irha.cz` — apex tier** | Chosen 2026-09-19. Named for where it is going (parent decision 12: the UI is the only thing ever published), and a rename breaks the registered OIDC redirect URI — the exact argument Mealie's spec used. Product-neutral on purpose: it survives replacing Open WebUI with something else, which `mealie.irha.cz` does not |
| Database | **Its own PostgreSQL**, `pgvector/pgvector:pg17`, StatefulSet in the `open-webui` namespace | Mealie's PostgreSQL is part of the *Mealie* ArgoCD app — its own manifest says so and says the placement is provisional. Putting this app's data inside it means a Mealie resync or rollback touches the assistant's database. A shared fleet-wide PostgreSQL with per-app credential provisioning (the shape MongoDB's provisioner Job gives us) is the right end state and the wrong thing to build now: it would mean migrating a live cookbook in order to stand up a playground. When a third consumer appears, both migrate in with `pg_dump`/restore, and nothing here makes that harder |
| Why not SQLite | Rejected | It would sit outside the logical-dump backup path (`~/homelab-backups/dump-all.sh`, outside this repo, already runs `pg_dump`), and it blocks `pgvector` — which is the whole point of picking this image |
| Vector store | `VECTOR_DB=pgvector` in the same database | `PGVECTOR_DB_URL` defaults to `DATABASE_URL`, so one database serves app data and embeddings. The default is `chroma`, which would put vectors in a second on-disk store with its own backup problem |
| Login | **Authentik OIDC**, local login form left ON initially | Same sequencing Mealie used: prove an Authentik login works *before* removing the fallback. Turning the form off is a follow-up edit, not part of the first landing |
| Storage | Longhorn PVCs: app data 20Gi at `/app/backend/data`, PostgreSQL 10Gi | Uploads and RAG source files live on disk, not in the database |

### PostgreSQL — two traps, both silent

**Do not copy Mealie's `fsGroup: 70`.** That value is correct for
`postgres:17-alpine`, where Alpine's postgres uid/gid is 70. `pgvector/pgvector:pg17`
is **Debian-based**, where it is **999**. Copying 70 leaves the volume owned by
the wrong group; root still chowns `PGDATA` in the entrypoint, so the pod comes
up fine and the ownership is simply wrong.

MEASURED 2026-09-19, not trusted: `docker run --rm pgvector/pgvector:pg17 id postgres`
→ `uid=999(postgres) gid=999(postgres)`, image is PostgreSQL 17.11 (Debian),
and `docker-library/postgres`'s bookworm Dockerfile creates the user with
`--gid=999 --uid=999`. **999 it is.**

**The extension is shipped, not enabled — and Open WebUI enables it itself.**
ANSWERED 2026-09-19 against the v0.11.3 tag: `PGVECTOR_CREATE_EXTENSION`
defaults to `true`, and `PgvectorClient.__init__`
(`backend/open_webui/retrieval/vector/dbs/pgvector.py`) issues
`CREATE EXTENSION IF NOT EXISTS vector` on first use. It succeeds because
`POSTGRES_USER` is this instance's bootstrap superuser. **No init step.** If
this database ever moves under a shared server where the app connects as a
non-superuser, this becomes a manual `CREATE EXTENSION` and
`PGVECTOR_CREATE_EXTENSION` should be set to `false` at that point.

Otherwise copy `gitops/k8s-manifests/server1/mealie/StatefulSet.postgres.yaml`
wholesale — including `volumeClaimTemplates` (so `kubectl delete sts` does not
delete the data) and the pinned-major-version reasoning (a major bump is a dump
and restore, never an image edit).

### Environment — names verified against Open WebUI's docs, values chosen here

Verify every name against the **pinned tag**, not against this list; these were
read from the main-branch docs on 2026-09-19.

Required:

- `WEBUI_URL=https://assistant.irha.cz` — required for OAuth; wrong value
  produces callback URLs that work from nowhere.
- `DATABASE_URL=postgresql://…` — **CORRECTED 2026-09-19.** This spec said
  `+asyncpg`, following upstream's multi-replica page. That is wrong for
  v0.11.3: `backend/requirements.txt` pins `psycopg[binary]==3.3.4` and
  `psycopg2-binary` and ships **no asyncpg at all**. `internal/db.py` builds a
  SYNC engine straight from `DATABASE_URL` (`create_engine`) for migrations and
  config loading, and derives the async one with `_make_async_url()`, which
  rewrites only `postgresql://` → `postgresql+psycopg://` and passes anything
  else through untouched. So `+asyncpg` fails twice: `InvalidRequestError` on
  the sync engine, `ModuleNotFoundError` on the async one.
- `VECTOR_DB=pgvector`.
- `WEBUI_SECRET_KEY` — from OpenBao. The docs say it **MUST** be set or
  sessions and OAuth behave erratically. This is a real secret, unlike the
  Ollama "API key".
- `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` (secret), `OPENID_PROVIDER_URL`
  (the `.well-known/openid-configuration` URL), `ENABLE_OAUTH_SIGNUP=true`,
  `OPENID_REDIRECT_URI=https://assistant.irha.cz/oauth/oidc/login/callback`
  — **CHANGED 2026-09-19.** This spec named `/oauth/oidc/callback`. v0.11.3's
  `main.py` routes BOTH `/oauth/{provider}/login/callback` and
  `/oauth/{provider}/callback`, and marks the second `# Legacy endpoint`.
  Authentik registers exactly one URI at `matching_mode: strict` and a later
  change breaks every login, so the non-deprecated path was taken while
  nothing was deployed and the choice was still free.
- `OAUTH_SCOPES=openid email profile roles` — the default omits `roles`, and
  without it the claim never arrives and every role check fails. This is the
  identical trap Mealie hit with `OIDC_SCOPES_OVERRIDE`; the comment in
  `gitops/k8s-manifests/server1/mealie/Deployment.yaml` explains it at length.

Role mapping, reusing this repo's ladder rather than a second vocabulary:

- `ENABLE_OAUTH_ROLE_MANAGEMENT=true`
- `OAUTH_ROLES_CLAIM=roles` — the `homelab roles` mapping emits `<app>.<role>`
  filtered to *this* application, so it is `roles`, not Authentik's unfiltered
  `groups`.
- `OAUTH_ALLOWED_ROLES=open-webui.user,open-webui.admin`
- `OAUTH_ADMIN_ROLES=open-webui.admin`

Chosen defaults worth stating explicitly:

- `OAUTH_MERGE_ACCOUNTS_BY_EMAIL` stays **`false`** (the default). Authentik's
  shipped `email` scope mapping returns a hardcoded `"email_verified": false`,
  and `User.email` is `unique=False` while `User.username` is `unique=True`.
  Merging on email is how one household member ends up logged into another's
  account. The same reasoning made Mealie match on `preferred_username`.
- **Does Open WebUI reject an unverified email? NO.** ANSWERED 2026-09-19:
  the string `email_verified` appears **zero times** in the entire v0.11.3
  source tree. Authentik's hardcoded `"email_verified": false` is simply not
  read. This is **not** the landing blocker it was for Mealie, and the rejected
  workaround (emitting `email_verified: true` from a local scope mapping, which
  would assert a verification that never happened for every application bound
  to that mapping) is not needed.
- `ENABLE_OAUTH_ID_TOKEN_COOKIE=false` — upstream's own recommendation; the
  cookie exists for backward compatibility.
- `ENABLE_PROFILE_IMAGE_URL_FORWARDING=false` — otherwise every viewer's
  browser fetches avatars straight from Authentik, leaking client IP,
  User-Agent and Referer to it on each load.
- `ENABLE_OAUTH_PERSISTENT_CONFIG` stays **`false`** (the default), so these
  environment variables remain authoritative and the Admin Panel's OAuth
  section is read-only. With it `true`, the database silently outranks git,
  which is the opposite of how everything else here works.
- `ENABLE_FORWARD_USER_INFO_HEADERS=true` — not needed today. It is what a
  future MCP tool server uses to know who is asking, and turning it on now
  costs nothing and means the tool-server spec does not have to restart this
  pod to get it.

### Added during implementation — a gap this spec did not cover

- `ENABLE_SIGNUP=false`. It defaults to **`True`** upstream, so with the login
  form left on, any LAN visitor self-registers. This does **not** block the
  first admin: `routers/auths.py` deliberately exempts the first user from that
  gate ("it auto-disables and can persist stale across a DB reset"), so the
  initial account is still created through the form. Mealie made the same call
  with `ALLOW_SIGNUP=false`.
- `DEFAULT_USER_ROLE=pending` (already the default, stated explicitly). It is
  the net under the `OAUTH_SCOPES` trap above. `get_user_role()` denies a login
  only when the roles claim is **present and matches nothing**; when the claim
  is missing entirely the gate does not run at all and the login falls through
  to this value. `pending` makes that failure inert. `user` would mean anyone
  with an Authentik account silently gets in.

Deliberately **not** set in this landing: `ENABLE_LOGIN_FORM=false` and
`OAUTH_AUTO_REDIRECT=true`. Both are correct eventually; both remove the
fallback that makes the first Authentik login debuggable.

## Deliverables

All paths relative to the repo root. **This spec owns every file in this list**
and no file outside it.

1. `gitops/k8s-manifests/server1/open-webui/ExternalSecret.yaml` — sync-wave
   `0`. `WEBUI_SECRET_KEY` and the PostgreSQL password, from
   `secret/server1/open-webui` in OpenBao.
2. `gitops/k8s-manifests/server1/open-webui/ExternalSecret.oidc.yaml` —
   sync-wave **`200`**, `OAUTH_CLIENT_SECRET` only. **CORRECTED 2026-09-19:**
   this spec said wave `0` "exactly like `mealie-oidc`" — `mealie-oidc` is in
   fact at `200`, and its own file records why. ArgoCD gates each wave on the
   previous one's health, and an ExternalSecret whose remote key is missing
   reports `SecretSyncedError`, which is Degraded. At wave 0 the expected
   "waiting for a human to paste the secret" state stops the sync dead before
   PostgreSQL ever applies. Consumed via `envFrom` with
   `optional: true`, exactly like `mealie-oidc`: the blueprint creates the
   provider, Authentik generates the secret, a human copies it into OpenBao
   once, and ESO materialises it. Until then the pod starts without OIDC rather
   than crashlooping.
3. `gitops/k8s-manifests/server1/open-webui/StatefulSet.postgres.yaml` —
   sync-wave `1`, `pgvector/pgvector:pg17`, `volumeClaimTemplates` 10Gi.
4. `gitops/k8s-manifests/server1/open-webui/Service.postgres.yaml`.
5. `gitops/k8s-manifests/server1/open-webui/PVC.yaml` — sync-wave `1`, 20Gi,
   `ReadWriteOnce`.
6. `gitops/k8s-manifests/server1/open-webui/Deployment.yaml` — sync-wave `2`,
   `strategy: Recreate` (ReadWriteOnce volume, single writer), the env block
   above, `reloader.stakater.com/auto: "true"` so a rotated secret or a
   newly-arrived OIDC secret actually restarts the pod. Environment is read
   once at boot; without the annotation a rotated value leaves a Running pod
   holding the old one, ArgoCD green throughout.
7. `gitops/k8s-manifests/server1/open-webui/Service.yaml`.
8. `gitops/k8s-manifests/server1/open-webui/HTTPRoute.yaml` — sync-wave `100`,
   `parentRefs` to the `websecure` Gateway listener.
9. `gitops/argocd-manifests/apps/household/OpenWebUI.yaml` — ApplicationSet,
   list generator, one element: `cluster: server1`,
   `clusterServer: https://192.168.1.200:6443`. Namespace `open-webui`,
   `CreateNamespace=true`. Copy the shape from `apps/household/Mealie.yaml`.
10. `gitops/k8s-manifests/server1/traefik/Certificate.server1-tls.yaml` — add
    `assistant.irha.cz` to `dnsNames`, with a comment in the style of the
    `qr.irha.cz` and `mealie.irha.cz` entries above it. **Apex SANs are public
    in Certificate Transparency logs** — the `ClusterIssuer.letsencrypt-prod.yaml`
    comment spells this out. `assistant` was chosen partly because it reveals
    less about the inventory than a product name would.
11. `gitops/helm-values/server1/external-dns.yaml` — add `assistant.irha.cz` to
    `domainFilters`. **A hostname missing from this list is ignored silently**:
    no error, no event, just a record that never appears.
12. `gitops/helm-values/server3/authentik-blueprints.yaml` — a new `open-webui`
    entry. Copy the `mealie` entry at line 275 and change:
    - `host: assistant.irha.cz` (explicit, apex tier)
    - `redirectPath: /oauth/oidc/callback`
    - `confidential: true` — Open WebUI requires `OAUTH_CLIENT_SECRET`; there
      is no PKCE-only mode
    - roles: **two rungs**, `admin` inherits `user`. `OAUTH_ALLOWED_ROLES` gates
      who may log in at all and `OAUTH_ADMIN_ROLES` grants admin, so a middle
      rung would be a claim nothing reads
    - `environments: [{ cluster: server1, stage: production }]` — no `local`;
      nobody runs a local Open WebUI against this IdP

`RootHousehold.yaml` needs **no change** — it recurses `apps/household/` and its
own comment already names Open WebUI as a future tenant.

## Verification — run these, record the answers here

1. **PostgreSQL really is PostgreSQL.** Confirm the tables landed there and the
   app is not quietly on SQLite. A working UI proves nothing about which
   database it wrote to.
2. **`vector` extension present and usable.** `\dx` in the database.
3. **HTTPS and DNS.** `assistant.irha.cz` resolves, serves a certificate whose
   SAN list contains it, and reaches the app.
4. **Authentik login works** for a household member holding `open-webui.user`.
5. **A member without the role is refused** — the gate is the point, and an
   allowlist that admits everyone looks identical to one that works.
6. **Admin mapping works**: a member of `open-webui-server1-production-admin`
   lands as an Open WebUI admin, not a plain user.
7. **A cloud model connection answers.** Use the Claude key already working in
   Mealie. This closes the loop without the sibling spec.
8. **Only then**, if Ollama has landed: add the Ollama connection and confirm a
   model responds through it.

Do not remove the local login form until 4, 5 and 6 all pass. Note what Mealie
learned: with the form off and Authentik unreachable — the realistic case being
OpenBao sealed after a reboot, which takes Authentik's secrets with it — there
is **no break-glass into the UI at all**. Recovery is fixing Authentik, or
setting the form back on and creating a local user.

## Working rules for whoever implements this

- **Commit with explicit pathspecs.** A sibling agent is working in this repo at
  the same time; `git add -A` will sweep their files into your commit. Never
  leave work staged.
- **This spec file stays uncommitted** while it is open, per the repo's
  convention for open specs. It is committed only when archived.
- **Do not edit `docs/architecture.md`.** Both specs would add rows to the same
  tables and collide. A single `sync-docs` pass runs after both land.
- **Do not edit `renovate.json5`** — the sibling spec owns that edit, and it
  covers this app's image too.
- **Do not re-trigger an ArgoCD sync to "help" a slow one.** Re-triggering kills
  in-flight hooks and wedges the app.
- The Authentik blueprint lands, then a human copies the generated client secret
  from the provider page into OpenBao **once**. Blueprint discovery is a cron at
  `:57`, hash-change only — the entry does not appear the moment you commit it.
- Show the diff and wait for review before committing.
