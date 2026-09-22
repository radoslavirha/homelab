# Ollama on server2

**Status:** **IMPLEMENTED and archived 2026-09-21.** Written 2026-09-19, landed the same
day as `079ba71` (CPU inference engine on server2, `ipAllowList`ed to server1). Verified
running 2026-09-21. The live reference is now `docs/architecture.md:51`, not this file —
read this one only for why it was built the way it was.

**Parent:** [`2026-09-13-personal-agents-platform.md`](../2026-09-13-personal-agents-platform.md)
— decision 1 (no GPU, CPU-only), decision 3 (server2 = LLM engine only),
decision 13 (the model is chosen by measurement).

**Sibling, buildable in parallel:**
[`2026-09-19-open-webui-server1.md`](2026-09-19-open-webui-server1.md). The two
specs share exactly one seam, defined below, and touch **no file in common**.
Either can land first.

**Not in this spec:** Open WebUI, Authentik, any MCP tool server, the Mealie AI
provider, embeddings-backed search, speech-to-text, and the model spike itself
(decision 13). This spec stands the engine up and pulls a first pair of models
so there is something to measure.

---

## Why this exists, and why it is smaller than it was

`docs/architecture.md:10` already records server2 as *"Platform-only since
2026-09-13 — its IoT estate was removed and it is being repurposed to host an
LLM."* The box is empty and earmarked. This spec is that repurposing.

**What changed on 2026-09-19:** Mealie's AI provider was pointed at Claude and
works. That proves Mealie's `chat.completions.parse` / `response_format`
contract end to end, and it means **no production feature depends on Ollama**.
Recipe import, book photos and Czech ingredient parsing all work today, on
cloud, with no infrastructure at all.

So Ollama is explicitly a **learning and experimentation engine**, not a
dependency. Nothing in this repo breaks if it is slow, wrong, or deleted. That
framing is load-bearing: it is why this spec accepts manual model pulls, a
single replica, and an IP allowlist instead of building a credential system.

Moving Mealie off Claude onto Ollama is a **later experiment, not a goal**
(stated 2026-09-19). The verification section below measures whether that would
even be possible, and records the answer. It does not act on it.

## The seam with the Open WebUI spec

One interface, and it is the only thing the sibling spec consumes:

| | Value |
| --- | --- |
| Base URL | `https://ollama.server2.homelab.irha.cz` |
| OpenAI-compatible path | `/v1` (so `…/v1/chat/completions`, `…/v1/embeddings`) |
| Native Ollama path | `/api` (so `/api/tags`, `/api/chat`, `/api/pull`) |
| Authentication | **none at the application layer** — see below |
| API key callers must send | any non-empty string; Ollama ignores it |

That last row is not a shortcut, it is what the callers require. Mealie's own
AI-provider docs state a key must be supplied for self-hosted providers *even
though the local service does not need it*, and Open WebUI's connection form
behaves the same way. The string is a placeholder, not a secret, and must not
be stored in OpenBao — storing it there would imply it protects something.

**The sibling spec does not block on this one.** Open WebUI is fully deployable
and testable against a cloud model connection (the same Claude key already
working in Mealie). Adding the Ollama connection is a config form filled in
after both are up.

## Security: Ollama has no authentication. None.

Verified against Ollama's own documentation (2026-09-19): there is no auth
mechanism, no token, no user concept. Any client that can reach the port can
run inference, **pull models, and delete models**.

server2's Traefik opens only 443 and 80 (`docs/architecture.md:115`), so the
service reaches the LAN through the Gateway or not at all. The protection is a
Traefik **`ipAllowList` middleware pinned to `192.168.1.200`** — the server1
node, which is where both callers (Open WebUI, Mealie) live.

Why this and not something stronger:

- **`basicAuth` does not fit.** Both callers send `Authorization: Bearer <key>`
  through an OpenAI SDK. A Basic challenge collides with that header rather
  than composing with it.
- **`forwardAuth` to Authentik does not fit.** The outpost issues a browser
  redirect; these are machine callers with no browser and no session.
- **A bearer-token-checking service would fit**, and is the documented upgrade
  path — a small service behind `forwardAuth`, or a Traefik plugin. It is a new
  component to operate, and it protects an engine that holds no data and whose
  worst-case compromise is "a LAN device used the CPU". Not worth it at this
  stage. Revisit if Ollama is ever reachable from outside the LAN, which
  the public-exposure spec must gate anyway.

**Consequence for administration:** the allowlist blocks your laptop too. Model
pulls therefore happen through `kubectl exec`, not `curl`. That is deliberate —
widening the allowlist to a roaming DHCP address is how an allowlist quietly
stops being one.

**Verify, do not assume, that the allowlist sees the right address.** server2's
Traefik runs `hostNetwork` with `externalIPs: 192.168.1.201`
(`gitops/helm-values/server2/traefik.yaml`), so it observes real client
addresses rather than a proxied one, and pod traffic leaving server1 should be
SNAT'd to that node's `192.168.1.200`. Should. Confirm it with a real request
from an Open WebUI pod and a real request from a laptop, and record both
outcomes, before declaring the middleware effective. An allowlist that silently
matches everything looks identical to one that works.

## Decisions taken for the implementer

| Item | Decision | Why |
| --- | --- | --- |
| Cluster | **server2**, namespace `ollama` | Parent decision 3. Matches how platform singletons are namespaced here (`mealie`, `headlamp`, `mongodb`), not the shared `production` namespace |
| Deployment | **Raw manifests** in `gitops/k8s-manifests/server2/ollama/` | Same call as Mealie: no official chart, single container, so a chart buys indirection and nothing else |
| Version | **`ollama/ollama:0.34.2`** — landed 2026-09-19 | Never `latest`. The tag has no `v`: the GitHub release is `v0.34.2`, the Docker Hub tag is `0.34.2`, and `ollama/ollama:v0.34.2` does not exist. amd64 config digest `sha256:c715bebf7699…`; 3.71 GB, pulled in 53 s |
| Renovate | Add a `kubernetes` manager pattern for `gitops/k8s-manifests/` to `renovate.json5` | `renovate.json5` currently gives patterns to the argocd and helm-values managers only, and Renovate's `kubernetes` manager ships no defaults — so image tags in raw manifests are **invisible**, which looks exactly like being up to date. Mealie's `Deployment.yaml` already carries this complaint in a comment. One edit fixes Ollama, Open WebUI and Mealie at once. **This spec owns that edit** so the sibling does not race it |
| Workload | `Deployment`, `strategy: Recreate`, separate `PersistentVolumeClaim` | Models are a ReadWriteOnce Longhorn volume with a single writer. RollingUpdate would start the new pod before the old released the volume and sit on `Multi-Attach error`. Same reasoning as Mealie's Deployment |
| Storage | **100Gi** Longhorn PVC at `/models`, `OLLAMA_MODELS=/models` | A dense 8B q4 is ~5 GB, an MoE ~18 GB; 100Gi holds a working set plus room to compare without evicting. **Correction, measured 2026-09-19:** server2 does NOT have a 500 GB SSD. It is a KINGSTON SHFS37A240G — a 240 GB SATA SSD, 7.5 years powered on, 51 TB lifetime writes, SMART PASSED. Longhorn reports `storageMaximum` 223 GiB with 67 GiB reserved (its default 30%), so ~156 GiB is schedulable and this claim takes 64% of it. There are genuinely no other PVCs and no orphaned volumes (zero PVs, `storageScheduled: 0`), so nothing is displaced — but the next PVC on server2 has ~56 GiB, and the same partition holds containerd's image store. Confirmed with the owner 2026-09-19 and kept at 100Gi |
| Idle behaviour | Leave `OLLAMA_KEEP_ALIVE` at its **default 5m** | The model unloads after five idle minutes, so an idle Ollama costs ~0 RAM and ~0 CPU. This is the whole answer to "I don't want a server dedicated to parsing recipes a few times a month" — it is a mostly-idle process, not a reserved machine |
| Concurrency | `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1` | 8 CPU cores. A second resident model does not add throughput, it adds swapping and memory pressure |
| Context | `OLLAMA_CONTEXT_LENGTH=8192` to start | Ollama's default is small; tool schemas and RAG chunks both eat context. Tunable — larger costs RAM and CPU per token |
| Exposure | `ollama.server2.homelab.irha.cz`, **homelab subtree** | Covered by the existing `*.server2.homelab.irha.cz` SAN on `server2-tls`, and `server2.homelab.irha.cz` is already in that cluster's ExternalDNS `domainFilters`. **Costs nothing and touches no shared file** — which is what makes this spec parallel-safe. An apex name would cost a SAN and a `domainFilters` entry, and this is an internal engine no human visits |
| Auth | `ipAllowList` middleware, `192.168.1.200` only | See the security section |
| Secrets | **None.** No ExternalSecret, no OpenBao path | There is nothing secret here. The callers' "API key" is a placeholder string |
| Model pulls | **By hand, `kubectl exec`**, documented in the runbook section | A PostSync Job pulling 5–20 GB is long and fragile, and re-triggering an ArgoCD sync kills in-flight PostSync Jobs and wedges the app. Automating this is a trap at this scale |

### Resource limits

- `requests`: `cpu: 500m`, `memory: 2Gi` — what an idle server with no model
  loaded actually needs.
- `limits`: **no CPU limit.** Inference is a burst that should use the cores it
  has; throttling only makes the same work take longer. Same argument as
  Mealie's manifest.
- `limits.memory`: `24Gi` of the node's 32 GB. High enough for an MoE plus
  context, low enough that an oversized model pull gets OOM-killed instead of
  taking the node's kubelet with it.

### Security context — verify before writing it

Do **not** copy Mealie's `fsGroup: 70`, and do not copy a `999` from a Debian
example either. Read the `ollama/ollama` image's own `USER` directive and
entrypoint at the pinned tag and set the context to match, or omit it and say
in the manifest comment that it was omitted deliberately and why. The failure
mode is a pod that starts fine and cannot write `/models`, which surfaces as a
model pull failing rather than as a permissions error.

**Answer, read from the image config blob at `0.34.2` on 2026-09-19:** the image
declares **no `USER`**, entrypoint `/bin/ollama`, cmd `serve`, `EXPOSE 11434`,
and env `OLLAMA_HOST=0.0.0.0:11434`. So it runs as uid 0. The manifest therefore
runs as root — matching the image, not a guess — and adds the hardening that
costs nothing at root: `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`. Ollama binds an
unprivileged port and writes only its own volume, so it needs no capability.
Talos enforces the `baseline` Pod Security Standard, which permits a root uid;
this namespace needs none of the `privileged` labelling `traefik` and
`longhorn-system` carry. Verified in the running pod: `uid=0(root)`.

### `HOME` is load-bearing — the trap this spec did not know about

The image sets **no `HOME`**, and `ollama serve` calls `initializeKeypair()`
*before* it listens (`cmd/cmd.go` at the `v0.34.2` tag), which calls
`os.UserHomeDir()` — and on Linux that **errors when `$HOME` is unset**, so the
server would exit before binding rather than start without a key.

The manifest sets `HOME=/models`. That defines the variable regardless of what
containerd does or does not default, and it puts the `id_ed25519` keypair on the
PVC so it survives a pod restart instead of being regenerated. Verified in the
running pod: `/models/.ollama/id_ed25519` exists alongside `blobs/` and
`manifests/`, and `/models/.ollama` does not collide with either.

A second, smaller trap found at the same time: because the Service is named
`ollama`, Kubernetes injects legacy service-link env vars into this pod —
`OLLAMA_PORT=tcp://10.108.68.66:11434` among them. Ollama reads `OLLAMA_HOST`,
not `OLLAMA_PORT`, so nothing breaks; but it is a second reason the manifest
sets `OLLAMA_HOST` explicitly rather than relying on the image's value.

## Deliverables

All paths relative to the repo root. **This spec owns every file in this list**
and no file outside it.

1. `gitops/k8s-manifests/server2/ollama/PVC.yaml` — 100Gi, `ReadWriteOnce`,
   sync-wave `1`.
2. `gitops/k8s-manifests/server2/ollama/Deployment.yaml` — pinned image,
   `Recreate`, env block above, probes below, resources above. Sync-wave `2`.
3. `gitops/k8s-manifests/server2/ollama/Service.yaml` — ClusterIP, port 11434.
4. `gitops/k8s-manifests/server2/ollama/Middleware.ipallowlist.yaml` — sync-wave
   `99`, in the `ollama` namespace. An HTTPRoute `ExtensionRef` is a *local*
   reference, so the Middleware must live in the route's own namespace — the
   same constraint documented in
   `gitops/k8s-manifests/server1/longhorn/Middleware.authentik.yaml`.
5. `gitops/k8s-manifests/server2/ollama/HTTPRoute.yaml` — sync-wave `100`,
   `parentRefs` to the `websecure` Gateway listener, `ExtensionRef` to the
   middleware above.
6. `gitops/argocd-manifests/apps/household/Ollama.yaml` — ApplicationSet, list
   generator with one element: `cluster: server2`,
   `clusterServer: https://192.168.1.201:6443`. Namespace `ollama`,
   `CreateNamespace=true`, `selfHeal` and `prune` on. Copy the shape from
   `apps/household/Mealie.yaml`.
7. `renovate.json5` — the `kubernetes` manager pattern described above.

`RootHousehold.yaml` needs **no change**: it discovers `apps/household/` with
`directory.recurse`, and its own comment already names Ollama as a future
tenant. Committing file 6 is the whole install step.

### Probes

`/api/tags` is the cheap, unauthenticated liveness signal — it lists installed
models and touches no model weights. Use it for readiness and liveness. Give
the startup probe room: the server itself starts in seconds, but it is sharing
a node with a Longhorn volume attach.

Do not probe `/` — it returns a fixed string and would stay green through a
broken model store.

**As built:** startup `5s × 60` (5 minutes), readiness `10s`, liveness
`30s × 6` with a `10s` timeout — about three minutes of consecutive failures
before a restart. The liveness numbers are deliberately slacker than Mealie's.
Saturating all eight cores is this workload's *normal* state, and a liveness
kill in the middle of a long generation would look like a crash loop caused by
the very thing the box exists to do. Measured: `/api/tags` answers in 2–4 ms
while a model is loading and while one is generating, so three minutes of
failures means genuinely wedged, not merely busy.

### One alarming boot log line that is not a problem

At startup Ollama logs `vram-based default context total_vram="0 B"
default_num_ctx=4096`. On a CPU-only box that reads like `OLLAMA_CONTEXT_LENGTH`
being ignored. It is not: `defaultNumCtx` is only consulted when
`envconfig.ContextLength()` is `0` (`server/routes.go` at the tag), and the line
is logged unconditionally. Confirmed at model load —
`llama_context: n_ctx_seq (8192) < n_ctx_train (40960)`. The 8192 is in effect.

## Verification — run these, record the answers here

A green pod proves nothing about any of this.

**Run 2026-09-19/20 against `ollama/ollama:0.34.2`. Results inline below.**

1. **The route answers.** From a laptop: expect the request to be **refused by
   the allowlist**, not to succeed. A 200 here means the middleware is not
   doing its job.
   → **PASS. Laptop (192.168.1.194) → HTTP 403.** Traefik's access log for that
   request: `ClientHost: 192.168.1.194`, `DownstreamStatus: 403`,
   `OriginStatus: 0` — the backend was never reached, and the refusal came from
   our own router (`RouterName: httproute-ollama-ollama-gw-traefik-…`), not from
   a missing host.
2. **The allowlist admits server1.** From a pod on server1:
   `curl https://ollama.server2.homelab.irha.cz/api/tags` → 200.
   → **PASS. Pod on server1 → HTTP 200.** Log for that request:
   `ClientHost: 192.168.1.200`, `DownstreamStatus: 200`,
   `ServiceURL: http://10.244.0.181:11434`.

   **Together these two are the answer to the spec's own worry.** The allowlist
   is not matching everything: two requests to the same URL, minutes apart, got
   403 and 200 purely on source address, and Traefik logged a *different* real
   client IP for each. Cilium's SNAT of pod egress to the node address
   (192.168.1.200) is confirmed, not assumed. `ipStrategy` is deliberately
   unset, so the match is on connection `RemoteAddr`, not on a client-supplied
   `X-Forwarded-For`.
3. **A model runs.** `kubectl exec` into the pod, `ollama pull <chat model>`,
   then a `/v1/chat/completions` call through the route. Record wall-clock
   latency and tokens/sec — decision 13 needs a baseline, and this is it.
   → **PASS, and the MoE bet paid off.** Identical prompt, through the route,
   from a server1 pod:

   | | `qwen3:8b` (dense) | `qwen3:30b-a3b` (MoE) |
   | --- | --- | --- |
   | On disk | 5.2 GB | 18 GB |
   | Cold load | 25.0 s | 81.5 s |
   | Prompt eval | 7.8 tok/s | **16.7 tok/s** |
   | Generation | 5.10 tok/s | **9.17 tok/s** |
   | Total wall clock | 35.8 s | 155.9 s (669 tokens emitted) |

   **The MoE is ~1.8× faster to generate and ~2× faster on prefill despite
   being 3.5× larger on disk.** That is the counterintuitive result this spec
   predicted, now measured on the actual box. Decision 13 has its number.

   Two caveats on that number. Generation decays with context — 11.1 tok/s at
   100 tokens, 9.9 at 300, 8.5 at 860 — so quote it as a range, not a constant.
   And the MoE's 81 s cold load is paid every time the model falls out of the
   5-minute keep-alive, which for occasional recipe parsing is *most* calls.
4. **Czech quality, eyeballed.** Three or four real Czech prompts. Not a
   benchmark; a smell test before investing in the spike.
   → **PARTIAL — and the split between the two models is the point.** Asked for
   three classic Czech soups, `qwen3:8b` returned *"Svíčková v polotučné vývaru"*
   (svíčková is a sauce dish, not a soup), *"Kyselostravá polévka"* (not a word)
   and *"Hovězí polévka"* (fine). `qwen3:30b-a3b` caught the same trap in its own
   reasoning — *"Svíčková is a famous dish, but it's actually a main course, not
   a soup"* — and answered **Kulajda, Kyselo, Bramborová polévka**, all three
   real. So the MoE is not merely faster, it is materially more correct on Czech.

   The longer Czech extraction prompt was **cancelled after 7m35s** at 2,596
   tokens; see the reasoning-verbosity finding below for why, and why continuing
   would only have re-learned it.
5. **Embeddings work.** `/v1/embeddings` against the embedding model returns a
   vector of the expected dimension.
   → **PASS.** `bge-m3` through the route returns an OpenAI-shaped
   `{"object":"list","data":[{"embedding":[…]}]}` with **exactly 1024 floats** —
   bge-m3's documented dimension. 7.07 s including a cold model load.

   Note the side effect: `OLLAMA_MAX_LOADED_MODELS=1` means an embeddings call
   **evicts the chat model**, and the next chat call pays the full cold load
   again (81 s for the MoE). A RAG loop that interleaves embedding and chat on
   this box would thrash. That is a consequence of the concurrency decision, not
   a fault in it — but it is a real constraint on what can be built here.
6. **The Mealie contract — the interesting one.** POST `/v1/chat/completions`
   with `response_format: {"type": "json_schema", …}` and a real schema. Mealie
   calls `client.chat.completions.parse(...)`, which is exactly this wire
   format. **Record whether Ollama's OpenAI-compatible layer honours it at the
   pinned version, partially honours it, or ignores it.** This is not a gate on
   anything — Mealie stays on Claude either way — but it is the single fact
   that decides whether moving Mealie local is ever worth attempting, and it
   costs one curl to learn.
   → **HONOURED — fully, not partially.** `response_format: {"type":
   "json_schema", "strict": true, …}` against `qwen3:30b-a3b` returned
   `finish_reason: "stop"` and this in `content`:

   ```json
   { "ingredients": [
       { "quantity": 1,   "unit": "kg", "food": "beef" },
       { "quantity": 200, "unit": "g",  "food": "carrots" },
       { "quantity": 2,   "unit": "",   "food": "onions" } ] }
   ```

   Every constraint holds: the `required` triple on each item, `quantity` as a
   JSON number rather than a string, `additionalProperties: false` respected.
   The tell that this is genuine grammar enforcement rather than a well-behaved
   model is the onions — no unit in the input, and instead of omitting the
   required key it emitted `""`. **Mealie's `chat.completions.parse()` would
   work against this engine at 0.34.2. The wire format is not the obstacle.**

   **Two things that are, and both are about the model, not Ollama:**

   - **Cost.** That three-ingredient extraction burned `completion_tokens: 1245`
     — roughly 1,200 of reasoning for ~45 of answer — at ~8 tok/s. Two and a
     half minutes per recipe against Claude's near-instant reply today.
   - **Silent translation, which is the dangerous one.** The input was Czech
     (*hovezi svickove, mrkve, cibule*); the output is English (*beef, carrots,
     onions*). Nothing asked for a translation. For a cookbook whose entire
     point is Czech ingredient parsing, anglicised food names are worse than a
     refusal — they look like success and would quietly poison the food table.

   Recorded as the spec asked, and it does not change anything: Mealie stays on
   Claude.

   **Also measured on the way (`/v1` vs the native path):** on `/v1` Ollama puts
   the thinking in its own `reasoning` field rather than in `content`, and
   `max_tokens` IS honoured with reasoning tokens counted against it — a request
   capped at 400 stopped at exactly 400 with `finish_reason: "length"` and an
   **empty `content`**. So capping tokens to control cost does not degrade the
   answer, it removes it.
7. **Idle cost.** Wait six minutes after a request and check the pod's memory.
   It should fall back toward the 2Gi request as the model unloads. If it does
   not, `OLLAMA_KEEP_ALIVE` is not behaving as documented and the "idle is
   free" premise of this spec is wrong.
   → **PASS, decisively.** Cgroup `memory.current` during MoE inference:
   **23.18 GB**. Five minutes after the last request, with `ollama ps`
   **empty**: **3.14 GB**. The 2Gi request is honest, the model really is
   evicted, and "an idle Ollama costs ~0 RAM and ~0 CPU" is measured rather than
   hoped. The ~1 GB above the request is page cache, which the kernel reclaims
   under pressure.

   This is the load-bearing result for the whole "I don't want a server
   dedicated to parsing recipes a few times a month" premise, and it holds.

### The finding this spec did not anticipate: reasoning verbosity

**`"think": false` does not stop a Qwen3 model reasoning.** Checked against
`api/types.go` at the pinned tag: `Message.Thinking` is populated only *"when
`ChatRequest.Think` is enabled"*, so `think: false` disables Ollama's **parsing**
of thinking tags rather than the thinking itself. On the native `/api/chat` path
the trace therefore lands verbatim in `message.content`, terminated by a literal
`</think>`.

Measured cost on this box:

| Prompt | Useful answer | Tokens actually emitted |
| --- | --- | --- |
| "Three Czech soups, one line each" | ~15 tokens | **669** |
| Czech ingredient extraction (6 items) | ~40 tokens | **2,596, cancelled at 7m35s** |
| Same extraction under a JSON schema | ~45 tokens | **1,245** |

At 8–10 tok/s that is the difference between a usable engine and an unusable
one, and it is the single biggest practical constraint discovered here. Three
untried ways out, in rough order of cheapness: `think: true` (the trace at least
lands in its own field where a consumer can drop it), Qwen3's own `/no_think`
soft switch in the prompt, or a non-reasoning model — `gpt-oss:20b` is the
obvious candidate and was deliberately not pulled, Qwen3 being the stronger
multilingual family.

**None of this is a regression.** Mealie runs on Claude and works. This engine
exists to be measured, and the measurement says a local Mealie needs the
reasoning problem solved first — and the Czech-to-English translation problem
after it.

## Models to pull first

**As pulled, 2026-09-19/20 — three, not two, ~24 GB of 100Gi.** The spec asked
for two and simultaneously asked for the MoE; with only two, "is an MoE faster
than a dense 8B on CPU" has no dense side to compare against, and that
comparison is the point. Confirmed with the owner before pulling.

| Model | Role | On disk |
| --- | --- | --- |
| `qwen3:8b` | dense chat baseline | 5.2 GB |
| `qwen3:30b-a3b` | MoE chat, 3B active | 18 GB |
| `bge-m3` | embeddings | 1.2 GB |

`gpt-oss:20b` (12.8 GB) was the other MoE candidate and was **not** pulled:
Qwen3 is the stronger multilingual family, and Czech is the thing being judged
here. Reconsider it only if Qwen3's reasoning verbosity (below) proves
unfixable.

The original sizing, kept for the record:

Two, not six. ~7 GB of 32.

- **One chat model** — Qwen3-8B-class dense, *or* an MoE in the
  Qwen3-30B-A3B / gpt-oss-20b class. Pick the current release at implementation
  time rather than trusting a name written here.
- **One embedding model** — `bge-m3` or `embeddinggemma`. Small, fast on CPU,
  strong on Czech, and not generative, so it cannot hallucinate — it only ranks.

**Pull the MoE even though it looks absurd for the box.** Few active parameters
per token means an MoE is often *faster and better on CPU than a dense 8B*
despite a much larger nominal size. That is counterintuitive enough that it is
the highest-value single measurement available here, and it directly informs
decision 13.

Vision and speech-to-text slots stay **empty**. Vision on 8 CPU cores is
minutes per page with poor Czech diacritics, and Claude already does Mealie's
book-photo import well. **Ollama cannot serve speech-to-text at all** — it has
no audio endpoint; that slot needs a separate service (`faster-whisper`) or
cloud, and is out of scope here.

## Runbook: pulling a model

```
kubectl -n ollama exec deploy/ollama -- ollama pull <model>
kubectl -n ollama exec deploy/ollama -- ollama list
```

The PVC survives a pod restart, so this is a once-per-model action. It is not
in git, and that is a known gap: a rebuilt cluster needs the pulls repeated.
Acceptable while this is an experiment; revisit if anything starts depending on
a specific model being present.

## Working rules for whoever implements this

- **Commit with explicit pathspecs.** A sibling agent is working in this repo at
  the same time; `git add -A` will sweep their files into your commit. Never
  leave work staged.
- **This spec file stays uncommitted** while it is open, per the repo's
  convention for open specs. It is committed only when archived.
- **Do not edit `docs/architecture.md`.** Both specs would add rows to the same
  tables and collide. A single `sync-docs` pass runs after both land.
- **Do not re-trigger an ArgoCD sync to "help" a slow one.** Re-triggering kills
  in-flight hooks and wedges the app.
- Show the diff and wait for review before committing.
