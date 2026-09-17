# Personal agents platform

**Status:** Brainstorm / working draft. Not a finished spec. Captured so the
thread survives between sessions — expect this to change as the conversation
continues. Not scheduled, not built. Last updated 2026-09-17 (second session:
sub-project split, identity model, language proposal, receipt research).

**Sibling:** [`2026-09-01-public-exposure.md`](2026-09-01-public-exposure.md)
— this project stays LAN-only for now, but **is intended to be opened to the
internet later** (stated 2026-09-17), so it is designed for that from the
start (decision 12). Revisit once that spec's gate (Authentik A5, a
*separate* initiative) opens.

---

## Why

Household personal-automation: scheduled recipe suggestions that learn
likes/dislikes, awareness of what's home (via receipt uploads), price
tracking, a weekly tech-news digest, a shopping list synced to Apple
Reminders, a summary across multiple calendars, and vacation-date planning.
Started from zero ("no clue how this works") and worked through several real
forks before landing on the shape below.

The second session widened it to **personalised agents for several people**:
a recipe "for me" vs. "for me and my wife"; a cycling trip where one person
prefers gravel and the other tarmac; hikes; later Garmin/Strava data. Cooking
is likely the first feature, not the only one. The infrastructure has to take
new agents without re-plumbing, and learning how the pieces connect is itself
a goal.

## Decisions made so far

1. **No GPU anywhere in the fleet** (verified by repo-wide search). The
   server2 LLM is CPU-only — small/quantized models. Slow is explicitly fine.
   server2 is 8 cores / 32 GB; the CPU model is not recorded in the repo.

2. Considered Anthropic's **Managed Agents** (hosted scheduling/search/memory)
   as an alternative to self-hosting. **Rejected**: it's API-only, no
   consumer UI, no claude.ai integration — a custom front-end would be
   needed either way, so the whole stack (including the brain) stays local
   rather than adding recurring cost and sending household data off-box for
   no UI benefit.

3. **server2 = LLM engine only.** Everything else — chat UI, tool servers,
   databases, scheduling — lives on **server1**.

4. **Reuse Authentik for login**, not a hand-rolled auth system. Verified
   this session: Authentik is fully deployed and already used for real LAN
   logins (since 2026-09-04); the "A5 — APIs verify tokens" gate only blocks
   *publishing to the internet* (per the public-exposure spec), **not**
   LAN-only apps like this one. A working reference pattern already exists
   in this repo: `qr-manager` (frontend does OIDC, backend verifies bearer
   JWTs against Authentik's JWKS) — see `gitops/helm-values/apps/qr-manager-ui/`
   and `gitops/helm-values/apps/qr-manager-api/`. Household member accounts
   (you, wife, kids) aren't stored in git (`docs/identity.md`) — added by
   hand in the Authentik UI, not a blocker.

5. **The "who is this for" problem** (you? you+wife? you+daughter? whole
   family?) is **not** a UI toggle/checkbox — a chat interface where you
   still have to click buttons defeats the point. Solved with a
   **tool-calling loop** instead: the model itself decides, from the
   sentence, which household member(s) to look up, by calling a narrow,
   validated tool (e.g. `get_preferences(name)`) that only resolves real,
   known names. The LLM does the language understanding; the tool code
   stays the deterministic gatekeeper on data access. Same mechanism as
   MCP. This is the resolution to an earlier muddle in the conversation
   between "LLM deciding access" (bad) and "LLM parsing intent, tool
   enforcing access" (fine). Refined by decisions 10 and 11: the *requester*
   is never guessed by the model.

6. **Toolchain, confirmed buildable today — not invented from scratch:**
   - **Open WebUI** — self-hosted chat UI, native MCP tool support (added
     v0.6.31, 2026), works with Ollama, has a Kubernetes Helm chart, and a
     documented working Authentik OIDC integration. Covers chat interface,
     multi-user login, and the LLM↔tools loop out of the box.
   - **Correction (2026-09-17):** Open WebUI itself is the MCP client; Ollama
     only returns tool calls through its chat API. `mcpo` is needed only to
     wrap third-party MCP servers that speak stdio. Our own tool servers
     speak MCP over streamable HTTP and need no bridge.
   - Model choice is no longer "Qwen3 8B" by reputation — see decision 13.
   - What's actually custom/ours to build: the **MCP server(s)** exposing
     household-specific tools — people and preferences, cookbook, calendar
     (CalDAV, three calendars: you/wife/family), inventory (from receipts),
     Reminders bridge, price lookup, news fetch. Nobody else has these;
     they're the real work.

7. **Reliability, stated honestly:** short tool chains (1-2 calls, e.g.
   "look up prefs → answer") work fine on an 8B CPU model. Long reasoning
   chains get flaky — errors compound per step. Real constraint, not a
   config problem. Factors into which agents stay fully local vs. which
   might warrant a cloud Claude call (flagged, not decided): price search
   and news digest touch no private data and lean on search/reasoning
   quality; recipes/calendar/receipts touch private household data and stay
   local.

8. **Scheduling gap — probably closed by Open WebUI itself (to verify).**
   Originally: Open WebUI is chat-first, so proactive agents need a separate
   scheduler. Open WebUI's docs (main branch, read 2026-09-17) now describe
   **Automations** (`ENABLE_AUTOMATIONS`: a prompt on an RRULE schedule, run
   as the user with a model and tools, output landing in a chat) and
   **per-user notification webhooks** (`ENABLE_USER_WEBHOOKS`, plus a
   `notify` tool the model can call). "Three recipes every day at 3 PM" may
   need no custom scheduler. Must be confirmed against the version actually
   deployed. Either way, **all household logic lives in the tool servers**;
   chat, automations, and any later bot are thin callers, so changing the
   interface never means rewriting the logic.

9. **Split into sub-projects**, each with its own spec → plan → build:

   | # | Sub-project | Depends on |
   | --- | --- | --- |
   | P0 | Platform core — Ollama (server2), Open WebUI + Authentik (server1), people/preferences tool server, the pattern for adding any tool server (deploy, auth, network policy, telemetry) | — |
   | P1 | Cookbook — store, "add this to the cookbook", manual entry, URL import with AI help | P0 |
   | P2 | Pantry — receipts (Lidl, Albert, Rohlik), ingredient normalisation, "cooked it" deducts stock | P0 |
   | P3 | Meal agent — preferences + cookbook (+ pantry once it exists) | P0, P1 |
   | P4 | Outdoor planner — routing engine + per-person preferences; Garmin/Strava later | P0 |
   | P5 | Proactive and push — schedules, notifications, shopping list, news, prices, calendar | P0 |

   **Start:** P0 + P1 + preference-only suggestions (P3 without pantry).
   Pantry and receipts are explicitly an addition for later.

10. **An account is not a person.** Who logs in and whom the data is about
    are separate concepts — the pattern behind Netflix profiles, Google
    Family, Mealie households, FHIR `Patient` vs. `RelatedPerson`. Shape
    (conceptual, not a schema yet):

    ```text
    person       (id, display_name, kind: member|guest)
    identity     (person_id, provider: authentik|telegram|garmin…, subject)   -- 0..n per person
    household    (id, name)
    membership   (person_id, household_id, role: adult|child|guest)
    relation     (person_id, other_person_id, type: spouse|sibling|child…)
    alias        (person_id, text)        -- "manželka", "Jana", "brácha"
    preference   (person_id, domain: food|cycling|hiking…, subject, strength: never|dislike|like|love,
                  source: stated|learned, note, updated_at)
    feedback     (person_id, item_ref, rating, comment, at)   -- raw events; learned preferences derive from these
    ```

    - Guests (a visiting brother) are a `person` with no `identity`.
    - Kids get a `person` now; adding an `identity` later gives them a login
      with no schema change. Not needed yet, must stay possible.
    - A Telegram account or Garmin connection later is another `identity`
      row, not a new concept.
    - `never` is a hard constraint; the rest are weights. For a group the
      tool merges deterministically: union of hard constraints, then
      combined weights.
    - Preference domains are open-ended: gravel vs. tarmac is the same table
      with `domain: cycling`.
    - Access rules ("can read because same household") live in tool-server
      code over these tables. Relationship-based authorization systems
      (Zanzibar-style: OpenFGA, SpiceDB) are the industry answer at scale and
      are YAGNI here; the data is shaped so it could move there.
    - "Who confirms a meal was cooked" belongs to the pantry (P2) and is
      parked with it. Recipe feedback is per person.

11. **The requester is known, not guessed.** Open WebUI MCP connections
    accept header templates expanded per request (`{{USER_EMAIL}}`,
    `{{USER_GROUPS}}`, …), so the tool server maps the caller to their
    `person` deterministically. The model only resolves *other* people
    ("manželka", "s bráchou") by calling something like
    `resolve_people(["manželka"])`; the tool validates against aliases and
    household membership. **Those headers are claims, not credentials:**
    tool servers accept calls only from Open WebUI (NetworkPolicy plus a
    shared secret) and are never exposed.

12. **Designed for internet exposure later.** Only the user-facing front
    (Open WebUI; possibly a bot later) is ever published. Tool servers stay
    cluster-internal. Unlike `qr-manager`, there is no browser→API path, so
    publishing the UI does not publish the APIs. The UI's hostname is chosen
    under the public-exposure spec's one-hostname rule from day one, so
    going public is one line of exposure config. Until then, away-from-home
    use is not supported.

13. **The model is chosen by measurement.** A short spike before P0 commits:
    20–30 real Czech/Slovak prompts with the expected tool call for each,
    run through Ollama on server2.

    | Criterion | Why it matters |
    | --- | --- |
    | Tool-call correctness | wrong person or argument = wrong answer |
    | Czech/Slovak quality | small models slip on grammar |
    | Latency | chat needs seconds; a 3 PM cron job may take minutes |
    | RAM fit | 32 GB on server2, context included |

    Candidates at spike time (refresh the list then): a dense small model
    (Qwen3-8B class), MoE models (Qwen3-30B-A3B / gpt-oss-20b class — few
    active parameters, often faster *and* better on CPU than a dense 8B),
    plus one cloud model as a quality ceiling. The model is per-agent
    configuration, so scheduled jobs can use a slower, better model than
    chat.

14. **Recipes are web-first, from Czech/Slovak *and* English sites**
    (2026-09-17). An empty cookbook must not mean no suggestions. Later, a
    configurable mix per schedule (favourites from the cookbook vs. new ones
    from the web). English recipes are translated for chat; one that gets
    saved is stored together with its translation. Consequences:
    - The discovery mechanism is open (see open questions).
    - Ingredients cross languages through the catalog's aliases
      (`all-purpose flour` and `hladká mouka` resolve to the same ID), so
      only free text — title, steps, notes — needs translating.
    - US units (cups, sticks, oz, °F) are normalised to metric on import,
      original kept. Cup → gram needs a per-ingredient density in the
      catalog.
    - US-only products (half-and-half, graham crackers) need a local
      substitute — a catalog property or a model suggestion, open.
    - Translating a *public* web recipe carries no household data, so it
      does not have to use the local chat model: a cloud model, or a
      dedicated local en→cs translation model (e.g. Mozilla's Bergamot
      models — Czech support to verify), are candidates. Translation joins
      the model spike's test set.
    - Every *suggested* recipe is remembered, not only saved ones, so repeats
      can be avoided and feedback has something to attach to.

## Proposed, not yet confirmed

**Language (2026-09-17).** Three layers:

- **Code, schema, enum values:** English (`strength: never|dislike|…`,
  `domain: food`).
- **Content** — recipe titles, steps, notes, free-text preferences: stored
  as written, tagged `lang` (`cs`/`sk`/`en`). No translation on write.
- **Shared vocabulary (ingredients):** language-neutral id (English slug,
  e.g. `tomato-cherry`) plus per-language names and aliases
  (`cs: rajče, cherry rajčátka, RAJČ.CHERRY` · `sk: paradajka`). Matching is
  Czech-to-Czech against aliases; the slug is only an identifier.

Why not English on write: receipts, Czech recipe sites and chat are all
Czech/Slovak. Translating on write adds a lossy step (`hladká mouka` is not
quite "plain flour"; `tvaroh` has no English equivalent), persists the small
model's mistakes, and then has to translate back on read.

Ingredient parsing: LLM structured output (JSON schema — Ollama supports it)
→ lemma (Czech declension: "2 lžíce cukru" → `cukr`; a deterministic
lemmatiser such as ÚFAL's MorphoDiTa is an option) → alias match → an
unknown term is asked about once and stored as a new alias. When a source
gives a stable product ID (Rohlik does; Lidl to verify), map the ID to the
ingredient and use text only as a fallback. Needed already for P1/P3, not
just the pantry: a `never` preference ("no mushrooms", an allergy) can only
be enforced deterministically against ingredient-level data.

## Topology

```text
server2: Ollama + model chosen by the spike — LLM engine only, nothing else
server1: Open WebUI (chat UI, Authentik OIDC login, automations) — the only thing ever exposed
         custom MCP tool server(s), cluster-internal — the actual household integrations
         datastore (engine still open, see below)
```

The LLM never touches data directly. It calls tools; tools are the only data
access path, and they validate against the known household-member list.

## Agents gathered so far

- **Recipes** — per-person preference learning ("no cucumbers"). "For me" /
  "for us" / arbitrary subsets ("me and my daughter", a visiting brother)
  resolved by the tool-calling loop, not UI toggles.
- **Cookbook** — "add this recipe to the cookbook" from chat; manual entry;
  import from a URL, with AI help where the page lacks structured data.
- **Receipts → inventory** (later, P2). Research 2026-09-17 — OCR is off the
  critical path for two of three shops:
  - **Lidl Plus:** receipts fetchable as JSON via the unofficial
    [`lidl-plus`](https://github.com/Andre0512/lidl-plus) library
    (reverse-engineered, can break). Lidl→Grocy sync projects already exist
    ([LidlToGrocy](https://github.com/salvadorbs/LidlToGrocy)).
  - **Rohlik:** an [official MCP server](https://www.rohlik.cz/stranka/mcp-server),
    including order history.
  - **Albert:** the Můj Albert app exports a receipt to Účtenkovník
    ([source](https://uctenkovnik.cz/blog/loyalty-apps/)); format not checked.
  - The hard part is normalising `RAJČ.CHERRY 250G` to an ingredient, not
    reading the text.
  - Existing open-source apps: **Grocy** (stock, consume a recipe's
    ingredients, shopping list); **Mealie** / **Tandoor** (cookbook, URL
    import). Adopt vs. build is open; being reviewed.
- **Trips and hikes** (P4) — routing is done by a routing engine; the LLM
  only turns intent and per-person preferences into its parameters. Strava's
  [API agreement](https://press.strava.com/articles/updates-to-stravas-api-agreement)
  (since 2024-11-11) allows an athlete's data to be shown only to that
  athlete and forbids AI training, so showing the wife's activities to her
  husband conflicts with it. Pulling from Garmin directly or from GPX/FIT
  exports avoids that.
- **Price tracking** — open tradeoff: fixed per-site scrapers (reliable,
  must define/maintain each site) vs. LLM + search-tool ("agentic search,"
  no site list needed, needs a paid/rate-limited search API, weaker on
  precise numeric extraction on a small model).
- **Weekly tech-news digest** — RSS feeds fetched, LLM summarizes.
- **Shopping list** — synced to Apple Reminders. Sync mechanism undecided.
- **Calendar summary** — across three calendars (you, wife, family) via
  CalDAV.
- **Vacation-date planning** — reasons over combined calendar free/busy plus
  constraints (e.g. school holidays) to suggest windows.

## Open questions — not yet decided

- **Recipe discovery mechanism** (decision 14): live search per request
  (search API → fetch → parse → filter) vs. a harvested corpus from chosen
  sites (local index, preferences filtered before the model sees anything)
  vs. a hybrid.
- **Hard dietary constraints:** real allergies or medical diets in the
  household? Decides how strict ingredient-level matching must be.
- **Language proposal** above — confirm or change.
- **Cookbook:** adopt Mealie/Tandoor vs. build our own.
- **Datastore engine:** a new PostgreSQL (fits the relational model;
  Tandoor requires it, Mealie supports it) vs. the existing MongoDB (already
  operated: provisioner, TLS, offsite logical dumps).
- **Delivery channel for scheduled output** until the internet exposure
  lands (Open WebUI chat + a notification target?).
- Verify Open WebUI Automations and user webhooks exist in the deployed
  version (decision 8).
- OCR for Albert receipts, if the export turns out to be an image (P2, later).
- Price-search API/approach (fixed scrapers vs. LLM+search tool), and
  whether that agent (and/or news digest) calls out to Claude's API instead
  of the local model, given the privacy/reasoning-quality tradeoff above.
- Apple Reminders sync mechanism (Shortcuts webhook vs. CalDAV vs. other —
  no existing integration in this repo to reuse).
- Authentik group/role setup specifics for the household (qr-manager
  pattern to copy, not yet applied here).
- Exact relationship to the public-exposure spec's timeline, once the
  Authentik A5 gate (a separate initiative) opens.

## Explicitly out of scope for this document

No Kubernetes manifests, Helm values, or DB schemas yet. This records the
shape of the conversation, not an implementation. That's for later, once the
open questions above narrow down and this is ready to become an actual
spec/plan.
