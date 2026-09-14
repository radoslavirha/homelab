# Personal agents platform

**Status:** Brainstorm / working draft. Not a finished spec. Captured so the
thread survives between sessions — expect this to change as the conversation
continues. Not scheduled, not built.

**Sibling:** [`2026-09-01-public-exposure.md`](2026-09-01-public-exposure.md)
— this project stays LAN-only for now. Some cluster services are expected to
go public soon; revisit once that spec's gate (Authentik A5, a *separate*
initiative) opens.

---

## Why

Household personal-automation: scheduled recipe suggestions that learn
likes/dislikes, awareness of what's home (via receipt uploads), price
tracking, a weekly tech-news digest, a shopping list synced to Apple
Reminders, a summary across multiple calendars, and vacation-date planning.
Started from zero ("no clue how this works") and worked through several real
forks before landing on the shape below.

## Decisions made so far

1. **No GPU anywhere in the fleet** (verified by repo-wide search). The
   server2 LLM is CPU-only — small/quantized models. Slow is explicitly fine.

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
   enforcing access" (fine).

6. **Toolchain, confirmed buildable today — not invented from scratch:**
   - **Open WebUI** — self-hosted chat UI, native MCP tool support (added
     v0.6.31, 2026), works with Ollama, has a Kubernetes Helm chart, and a
     documented working Authentik OIDC integration. Covers chat interface,
     multi-user login, and the LLM↔tools loop out of the box.
   - **Ollama** doesn't speak MCP natively — needs a small bridge (`mcpo`)
     to translate. Recommended CPU-friendly tool-calling model: **Qwen3 8B**
     (~5GB RAM at Q4), currently a strong pick for tool-calling reliability
     at homelab-CPU scale.
   - What's actually custom/ours to build: the **MCP server(s)** exposing
     household-specific tools — preferences, calendar (CalDAV, three
     calendars: you/wife/family), inventory (from receipts), Reminders
     bridge, price lookup, news fetch. Nobody else has these; they're the
     real work.

7. **Reliability, stated honestly:** short tool chains (1-2 calls, e.g.
   "look up prefs → answer") work fine on an 8B CPU model. Long reasoning
   chains get flaky — errors compound per step. Real constraint, not a
   config problem. Factors into which agents stay fully local vs. which
   might warrant a cloud Claude call (flagged, not decided): price search
   and news digest touch no private data and lean on search/reasoning
   quality; recipes/calendar/receipts touch private household data and stay
   local.

8. **Known gap, unresolved:** Open WebUI is chat-first — you ask, it
   answers. The proactive agents (weekly recipe suggestion, weekly news
   digest, price-drop alerts) need something to push output on a schedule
   without being asked. Not something Open WebUI does itself. Needs a small
   scheduling piece triggering into this stack.

## Topology

```
server2: Ollama + Qwen3-class model — LLM engine only, nothing else
server1: Open WebUI (chat UI, Authentik OIDC login)
         mcpo bridge (Ollama tool-calling <-> MCP)
         custom MCP tool server(s) — the actual household integrations
         (scheduling mechanism — still open, see below)
```

The LLM never touches data directly. It calls tools; tools are the only data
access path, and they validate against the known household-member list.

## Agents gathered so far

- **Recipes** — per-person preference learning ("no cucumbers"). "For me" /
  "for us" / arbitrary subsets ("me and my daughter") resolved by the
  tool-calling loop, not UI toggles.
- **Receipts → inventory** — photo uploaded, OCR extracts text, parsed into
  structured items, updates a pantry/inventory store.
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

- OCR library for receipts.
- Price-search API/approach (fixed scrapers vs. LLM+search tool), and
  whether that agent (and/or news digest) calls out to Claude's API instead
  of the local model, given the privacy/reasoning-quality tradeoff above.
- Apple Reminders sync mechanism (Shortcuts webhook vs. CalDAV vs. other —
  no existing integration in this repo to reuse).
- How proactive/scheduled agents get triggered, given Open WebUI is
  chat-first.
- Authentik group/role setup specifics for the household (qr-manager
  pattern to copy, not yet applied here).
- Exact relationship to the public-exposure spec's timeline, once the
  Authentik A5 gate (a separate initiative) opens.

## Explicitly out of scope for this document

No Kubernetes manifests, Helm values, or DB schemas yet. This records the
shape of the conversation, not an implementation. That's for later, once the
open questions above narrow down and this is ready to become an actual
spec/plan.
