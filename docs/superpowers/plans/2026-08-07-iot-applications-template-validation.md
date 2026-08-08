# `iot-applications` — Validated Config Templates

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** `apps.<name>.templates.<template>.validate` generates an initContainer that checks the rendered config **before the main container starts**, so a config the app cannot use produces `Init:CrashLoopBackOff` instead of a Running, Ready pod serving a broken application.

**Repo:** `/Users/radoslavirha/dev/irha/homelab`.

**Requested by:** `iot-miniservers` — `docs/superpowers/specs/2026-08-06-iot-app-health-checks-frontend.md` (decision 2). That spec builds the validator images; this one builds the chart support they plug into. Neither is useful without the other.

**Status:** **done and running in cluster as of 2026-08-08.** The `iot-miniservers` half shipped — both validator images are published and pinned (`qr-manager-ui-config-validator:0.7.0`, `homelab-dashboard-ui-config-validator:0.4.0`), so the ordering gate below is satisfied and no backfill was needed. Chart support, both UIs opted in, and the failure path exercised for real. Two corrections came out of the rollout: decision 4a's `runAsUser` claim, and a missing `seccompProfile`.

**Related:**

| Plan | Relationship |
| --- | --- |
| `2026-08-06-iot-app-health-checks.md` | Parent. This closes the gap its UI steps leave open — a `/healthz` that returns `200 ok` from a pod whose config is unusable |
| `2026-08-06-iot-app-health-checks-homelab.md` | Sibling. Adds probes / `lifecycle` / `terminationGracePeriodSeconds` to the same two template files. **Land that first**, or resolve the overlap by hand |
| `2026-08-05-stakater-reloader.md` | Makes this materially more valuable — see "Why now" |

---

## Why the chart, and why now

### The gap

`templates:` renders a Jinja2 source from a ConfigMap into an `emptyDir` via an `objectiflibre/jinja-init` initContainer, and the main container mounts the result (`templates/deployment.yaml:55-110, 161-170`). Nothing checks what came out.

That is fine for an app that validates its own config at startup. The three Ts.ED APIs do: `@radoslavirha/tsed-configuration` loads the file into a `ConfigModel` and an invalid one fails the boot, so the pod CrashLoops on its own. **The two nginx UIs cannot** — nginx has no JSON parser and no way to reason about the file it serves. It starts happily, serves `200 ok` on `/healthz`, goes Ready, and every user gets a blank page while ArgoCD reports `Healthy`.

So the invariant "a pod that is Ready can actually run the app" is currently satisfied by the APIs and silently violated by the UIs.

### Why now

Two things landing at the same time raise the stakes:

- **Stakater Reloader** (`2026-08-05-stakater-reloader.md`) removes `checksum/config` and makes Reloader the only restart mechanism. A config edit then triggers an **automatic, unattended rollout**. Without validation, a bad edit rolls itself out: the new pod goes Ready, the old one is torn down, and nobody is watching. With validation, the new pod fails init and the old one keeps serving.
- **The health-check plans** are adding probes to the UIs. A probe that cannot fail is worse than no probe, because it manufactures confidence. Validation is what gives the UI probes something real to say.

### Why not leave it to the app

For the APIs, we do — see decision 1. For nginx there is no in-process option that is not worse:

- nginx cannot do it. No JSON parser, no scripting. `njs` is a restricted runtime that will not run a real schema library, so using it means reimplementing the schema in a second language.
- Putting a Node runtime in the nginx image to run the schema at entrypoint was drafted and rejected in the requesting spec: it makes a static file server permanently inherit Node's CVE stream for 200 ms of startup work, and the Kubernetes docs describe init containers as existing precisely to hold *"utilities or custom setup code not present in the app image"*, to *"block or delay app container startup until preconditions are met"*, and to *"enhance security by isolating potentially risky tools, thus limiting the attack surface of the app container image"*.

All three of those sentences describe this task. The chart is the right place.

---

## Key decisions

### 1. The invariant is unified; the mechanism is not, and should not be

The rule this chart enforces is **"config is proven usable before the app serves"**. How that is satisfied differs by what the app can do for itself:

| App type | Mechanism | Chart involvement |
| --- | --- | --- |
| Ts.ED APIs | `ConfigModel` validation during boot; an invalid config fails the process | none — `validate` stays unset |
| nginx UIs | validating initContainer running the app's own schema | `validate: true` |

Adding an initContainer to the APIs as well would mean either a second, drifting expression of `ConfigModel`, or a validator image that boots the whole Ts.ED app just to parse a file. Both are worse than what they already have. **`validate` is opt-in and the APIs do not opt in.**

What *is* unified is the chart-level vocabulary: one key expresses the requirement, any app may use it, and the values files read the same way whether an app self-validates or not.

### 2. A `validate` key on the template, not a generic `initContainers:` list

The generic escape hatch was considered first and rejected on a concrete problem: a hand-written initContainer must mount the rendered output, whose volume name is `{{ include "iot-applications.identifier" $ctx }}-tpl-out-{{ $templateName }}`. A values file would have to reconstruct that string from chart internals — `identifier` is itself `component[-partOf]-name` truncated to 63 characters. Any change to the naming helper would silently break every values file that guessed it.

Validation is a property *of a rendered template*, so it belongs on the template entry, where the chart already knows the volume name, the file name and the app's image coordinates:

```yaml
    templates:
      config:
        file: config.json
        path: /usr/share/nginx/html/config.json
        subPath: config.json
        validate: true      # ← the whole feature, from the values side
```

A generic `initContainers:` passthrough can still be added later if something genuinely unrelated to templates ever needs one. Nothing needs it today, and adding it now would just be a second way to express this one.

### 3. The validator image is derived from the app image, not named in values

```text
{{ $application.image.repository }}-config-validator : {{ $application.image.tag }}
```

The tag is reused verbatim. This is the entire answer to "how do we stop the validator drifting from the app it validates": the existing `deploy.json` bump moves `image.tag`, both images move together, and a mismatched pair is unrepresentable. No second `yamlPath`, no second field for a human to forget.

`validate` also accepts a map for the case the convention does not fit:

```yaml
        validate:
          repository: ghcr.io/radoslavirha/some-other-validator   # optional, defaults to <app repo>-config-validator
          tag: "1.2.3"                                            # optional, defaults to the app's image.tag
          args: ["--strict"]                                      # optional, appended after the config path
```

`true` is sugar for `{}`. Keep the derived default the documented path — a values file naming its own image is the exception, not the pattern.

### 4. The validator reads the emptyDir, so `path` and `subPath` do not matter to it

This is what keeps the feature simple, and it is worth stating because it is not obvious. `templates.<name>.path` and `.subPath` are configurable and differ by app type — APIs mount the whole directory (`path: /home/app/config`), UIs mount a single file (`path: /usr/share/nginx/html/config.json` + `subPath: config.json`). Both are properties of **the main container's** mount.

The validator does not use either. It mounts the `tpl-out-<template>` emptyDir at a fixed internal `/config` — exactly as `jinja-init` does — and reads `/config/{{ $template.file }}`, which is where `JINJA_DEST_FILE` put it. The only values key it depends on is `file`, which the existing `iot-applications.validators.template` helper already requires.

So an app can move its config anywhere in its own filesystem without touching validation, and the validator's contract is one argument: an absolute path to a JSON file.

### 4a. The validator contract, as built

The `iot-miniservers` side is implemented, so this is observed behaviour rather than intent. Build against it:

| Property | Value |
| --- | --- |
| Base image | `node:24-alpine` |
| User | `USER node` (uid 1000). ~~Satisfies `runAsNonRoot: true` without a chart-supplied `runAsUser`~~ — **this was wrong, see below** |
| `ENTRYPOINT` | `["node", "/app/validate-config.js"]` |
| `CMD` | `["/config/config.json"]` — a local-run default only; the chart always supplies the path as an arg |
| Config path | **argv[1]**, not baked in. Verified against a non-default filename (`/config/production.json`) |
| Exit code | `0` valid, `1` on unreadable / non-JSON / schema failure |
| Failure output | `stderr`, Zod's `prettifyError` — names the failing path, e.g. `✖ Invalid URL → at apiBaseURL` |
| Writes | none — compatible with `readOnlyRootFilesystem: true` |
| Size | ~350 KB bundle on top of `node:24-alpine`; both validators share the base layer |

> **Corrected 2026-08-08, in the cluster.** `USER node` does **not** satisfy `runAsNonRoot: true`. It is a *name*, and the kubelet cannot resolve a name to a UID, so it refuses to start the container:
>
> ```text
> CreateContainerConfigError: container has runAsNonRoot and image has
> non-numeric user (node), cannot verify user is non-root
> ```
>
> This fired on both `sandbox` clusters the moment `validate: true` first synced. The chart now sets `runAsUser: 1000` explicitly (the `node` user's UID, confirmed with `id` inside the image), overridable via `validate.runAsUser` for a validator built on a different base. Only a numeric UID *in the image* would have made the chart-side setting optional.
>
> The failure mode was benign, and instructively so: the pod sat `Pending` on the init container while the previous pod kept serving the ingress. A chart bug in the validation mechanism was contained by the same fail-closed property the mechanism exists to provide.
>
> `seccompProfile: RuntimeDefault` was added at the same time — the namespaces run PodSecurity `restricted` in warn mode, and it was the only thing keeping this container from satisfying it.

Two behaviours worth knowing when writing the chart:

- **It never prints config values.** Zod reports paths and expected types only, and there are tests pinning that against a sentinel secret. So `kubectl logs` on a failed validator is safe to read and safe in Loki — which matters because `homelab-dashboard-ui`'s config carries `unifi.apiKey`.
- **Missing and unparseable files are already caught earlier**, by the nginx entrypoint guard in the app image. The initContainer's unique contribution is *schema* validation: a file that exists and is valid JSON but is semantically wrong — an empty `{{ SECRET_* }}` substitution, a URL without a scheme. Do not over-scope the chart work trying to re-cover the first two.

### 5. Ordering is guaranteed by construction

Both containers are emitted inside the same `range` over `templates`, with the validator immediately after the `jinja2` container for that template. initContainers run sequentially in declaration order, so the validator always sees rendered output, never Jinja2 source. Rendering this in a second loop, or from a separate values key, would put that guarantee at the mercy of map iteration order — Helm sorts map keys, but relying on that for a correctness property is not worth the cleverness.

### 6. The validator container is unprivileged and reads one file

`runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, all capabilities dropped. It reads one file and exits; nothing it does needs more. This is the cheapest place in the chart to get a security context right, and it sets the pattern for `containerSecurityContext` which is documented but unused today.

All four are compatible with the image as built (decision 4a): it declares `USER node`, so no `runAsUser` is needed from the chart, and it writes nothing, so `readOnlyRootFilesystem` needs no `emptyDir` for scratch space. Assert this in the unit tests so a future validator image that wants to write cannot quietly loosen it.

---

## Steps

### 1. Chart: validate the new key

- [x] `templates/_helpers.tpl` — extend `iot-applications.validators.template` (currently checks `content` / `path` / `file`, lines 94-106) to reject a malformed `validate`:
  - `validate` may be absent, a boolean, or a map. Anything else `fail`s with the same message style as the existing checks (`[apps.%s.templates]`).
  - When it is a map, `repository`, `tag` and `args` are the only permitted keys — `fail` on unknown ones. A typo that silently disables validation is exactly the failure this feature exists to prevent.
- [x] Add a helper `iot-applications.template.validatorImage` taking `(dict "application" … "template" …)` and returning the resolved `repository:tag`, so `deployment.yaml` and `rollout.yaml` cannot drift in how they derive it.

### 2. Chart: render the initContainer

- [x] `templates/deployment.yaml` — inside the existing `range $templateName, $template` block (line 58), immediately **after** the `…-jinja2` container:

```yaml
        {{- if $template.validate }}
        - name: {{ include "iot-applications.identifier" $ctx }}-{{ $templateName }}-validate
          image: {{ include "iot-applications.template.validatorImage" (dict "application" $application "template" $template) }}
          imagePullPolicy: {{ $application.image.pullPolicy | default "IfNotPresent" }}
          args:
            - "/config/{{ $template.file }}"
            {{- with (ternary dict $template.validate (kindIs "bool" $template.validate)).args }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          securityContext:
            runAsNonRoot: true
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          volumeMounts:
            {{- /* Same emptyDir jinja-init wrote to — validate the rendered output. */}}
            - name: {{ include "iot-applications.identifier" $ctx }}-tpl-out-{{ $templateName }}
              mountPath: /config
        {{- end }}
```

  - Resources are deliberately omitted: the container runs for well under a second and the chart sets no defaults for initContainers today. If the cluster ever gets a LimitRange that rejects unspecified requests, add them then rather than guessing now.
- [x] `templates/rollout.yaml` — apply the identical block at the equivalent position (the `range` at line 54). Argo Rollouts is not installed in any cluster, but the two templates are kept in step as a rule, exactly as the probe plan does.

### 3. Document

- [x] `values.yaml` — document `validate` in the commented `templates:` block (around line 92-115), covering: what it does, that it is opt-in, the derived image convention, the map form, and the reason the APIs do not use it (they validate in-process). Include the one-line copy-paste.
- [x] `Readme.md` — the `templates` section already explains that the file is rendered once at pod start and points at Reloader. Add a paragraph: apps that cannot validate their own config should set `validate: true`, and what the failure looks like (`Init:CrashLoopBackOff`, the reason in `kubectl logs <pod> -c <identifier>-<template>-validate`).

### 4. Test

- [x] `tests/validators_test.yaml` — `validate` accepts absent / `true` / `false` / a map; `fail`s on a string, a number, and a map with an unknown key.
- [x] `tests/deployment_test.yaml`:
  - initContainer rendered when `validate: true`, absent when unset or `false`.
  - It appears **after** the `…-jinja2` container for the same template.
  - Image derived from `image.repository` + `-config-validator` and `image.tag`; overridden correctly by the map form.
  - `args[0]` is `/config/<file>` and tracks a non-default `file` value.
  - `volumeMounts[0].name` matches the `tpl-out-<template>` volume the jinja2 container writes to.
  - Security context is present.
  - Two templates with `validate` on only one generate exactly one validator.
- [x] Mirror the render assertions in a `rollout` test if that file has coverage; otherwise note the gap rather than silently leaving the template untested.
      `rollout.yaml` had **no** test file at all, so the gap was closed rather than noted: new `tests/rollout_test.yaml` covers Rollout emission, the validator initContainer and its ordering, plus the probe / `lifecycle` / `terminationGracePeriodSeconds` blocks the sibling probe plan added to the same file.
- [x] Refresh `tests/__snapshot__` if the suite snapshots rendered output. — the directory is empty; no suite snapshots output, nothing to refresh.
- [x] `helm unittest gitops/helm-charts/iot-applications` — CI runs the same via `.github/workflows/helm-chart-ci.yaml`. **72 assertions across 6 suites, all passing.**

### 5. Adopt

Blocked on the validator images existing — see the ordering gate below. **Gate satisfied 2026-08-08**, so this landed.

- [x] `gitops/helm-values/apps/qr-manager-ui/**sandbox.yaml**` — `validate: true` on `templates.config`. Not `base.yaml`: the sibling probe plan stages this app's health block in `sandbox.yaml` first, and splitting the two across different files would let a probe land in production without the validation that makes it meaningful. Promoted to `base.yaml` together, after a watched sandbox rollout.
- [x] `gitops/helm-values/server3/homelab-dashboard-ui.yaml` — same.
- [x] Leave all three APIs untouched (decision 1).

#### Already true, before this chart change lands

The merged frontend work changed how the UI images behave on their own. Worth knowing, because it affects what you will see in the cluster the next time those image tags are bumped — independently of anything here:

- **A ConfigMap that fails to mount is now fatal.** The images no longer ship a development `config.json` (`build.copyPublicDir: false` in each `vite.config.ts`), and the nginx entrypoint refuses to start without one. Previously a failed mount was invisible: the pod served `http://localhost:4002`, or the dashboard's placeholder `"apiKey": "your-api-key-here"`, and reported itself perfectly healthy.
- **`/healthz` is now an exact match** on `homelab-dashboard-ui` (it was a prefix, so `/healthzabc` also returned `ok`) and **exists at all** on `qr-manager-ui`.
- **`homelab-dashboard-ui` uses the stock nginx entrypoint pipeline**, replacing its custom `ENTRYPOINT`. `STOPSIGNAL SIGQUIT` and nginx-as-PID-1 verified intact, so the probe plan's graceful-shutdown assumptions still hold.

None of this requires a values change. It does mean the first tag bump after that merge is the moment a latent ConfigMap problem would surface — so bump `sandbox` first and confirm, as the probe plan's gate already requires.

---

## Ordering gate

Same shape as the probe plan's, and for the same reason — a values change that references something not yet in the cluster breaks a working app.

### How the validator images get published

`iot-miniservers`' `.github/workflows/docker-build-app.yaml` builds the app image from `target=$(basename "$APP_PATH")` and `image=ghcr.io/radoslavirha/$(jq -r .name package.json)`, tagged `:latest` and `:<package.json version>`. It now also builds a second image in the same job when the Dockerfile contains a matching `-config-validator` stage:

```text
ghcr.io/radoslavirha/qr-manager-ui:0.6.0
ghcr.io/radoslavirha/qr-manager-ui-config-validator:0.6.0
```

Both tags come from the same `package.json` in the same workflow run, which is what makes this chart's derived image reference safe: `<repository>-config-validator:<tag>` cannot resolve to a validator built from a different commit than its app.

**Backfill required.** `qr-manager-ui@0.6.0` and `homelab-dashboard-ui@0.3.0` were released *before* that workflow step existed, so their validators are missing from GHCR. Re-running `docker-build-app.yaml` via `workflow_dispatch` (`APP_PATH=ui/<app>`, `PUBLISH=true`) republishes the app image at the same version and adds the validator.

> **No backfill was needed.** Both UIs were released again afterwards — the values files now pin `qr-manager-ui@0.7.0` and `homelab-dashboard-ui@0.4.0`, both built by the workflow that includes the validator step. Confirmed by anonymous GHCR manifest fetch: `qr-manager-ui-config-validator:0.7.0` and `homelab-dashboard-ui-config-validator:0.4.0` both return `200`.
>
> One property worth recording: the validator images are **`linux/amd64` only**. Every node on server2 and server3 is `amd64`, so this is fine today, but an arm64 node added to any cluster would `CreateContainerError` on the validator while the app image itself might still run.

### Sequence

1. Confirm `ghcr.io/radoslavirha/<app>-config-validator` exists **at the exact tag the values file pins** — backfill first if the app was released before the workflow step landed.
2. Only then set `validate: true`.

Setting it earlier makes the initContainer reference a nonexistent image → `ImagePullBackOff` → the pod never starts. **This fails closed, not open**, so it is a recoverable mistake rather than an outage, but it will still stop a rollout.

The chart change itself (steps 1-4) is inert without a values file opting in, so it can land at any time.

---

## Verification

`AGENTS.md`: a green sync status is not evidence.

> **Executed 2026-08-08.** Results inline below. The deliberate-failure run is commit `7b89c14`, reverted by `0818719`.

- [x] **Renders as intended:** `helm template` a values file with `validate: true` and confirm initContainer order, image, args and mounts by eye once, before trusting the unit tests.
      Done for both UIs against their real values files: `…-config-jinja2` then `…-config-validate`, image `ghcr.io/radoslavirha/<app>-config-validator:<app tag>`, `args: ["/config/config.json"]`, one volumeMount of the `tpl-out-config` emptyDir at `/config`.
- [x] **Pre-flight: the schema accepts what the values files actually render.** Not in the original list, and it is the check that decides whether `validate: true` is safe to commit. The live `config.json` was pulled from each running pod (`qr-manager-ui` in `sandbox` and `production`, `homelab-dashboard-ui` on server3) and fed to the matching validator image locally: three configs, three `exit=0`. A deliberately emptied `apiBaseURL` was rejected with `✖ Invalid URL → at apiBaseURL`, `exit=1`, and no value in the output. So the initContainer will pass on today's config and fail on the case it exists for.
- [x] **Happy path unchanged:** verified on server1 + server2 `sandbox` and server3 `homelab` — `…-config-jinja2` then `…-config-validate`, both `Completed exit=0`, validator log `is valid`, main container Ready with `0` restarts.
- [x] **Ordering holds:** `…-jinja2` before `…-validate` on every pod checked.
- [x] **It actually fails on a bad config.** In `sandbox`, break `templates.config.content` and expect: new pod `Init:CrashLoopBackOff`, the reason named in `kubectl logs <pod> -c <identifier>-config-validate`, and **the old pod still Ready and still serving the ingress**. Revert.

  Use a case only the *schema* can catch, since the app image's entrypoint guard already handles missing and unparseable files. These are the exact failures reproduced locally against the built validator image:

  | Broken content | Expected validator output |
  | --- | --- |
  | `"apiBaseURL": ""` — an empty `{{ VAR_* }}` / `{{ SECRET_* }}` substitution | `✖ Invalid URL → at apiBaseURL` |
  | `"apiBaseURL": "localhost:4002"` — scheme dropped | `✖ Invalid URL → at apiBaseURL` |
  | dashboard: `"apiKey": ""` | `✖ Too small: expected string to have >=1 characters → at unifi.apiKey` |

  The empty-substitution case is the one that matters: it is valid JSON, so nothing before the schema catches it, and it is what silently ships a blank page today.
- [ ] **No secret leaks.** In the same logs, confirm no config *values* appear — `homelab-dashboard-ui`'s config carries `unifi.apiKey`. The validator image is responsible for this, but verify it here, because this is where a leak would actually reach Loki.
- [x] **APIs are unaffected:** confirm the three Ts.ED apps render no validator initContainer and their pods are untouched by the chart bump.

---

## Follow-ups

- **Generic `initContainers:` passthrough.** Deliberately not built (decision 2). Revisit only when something that is *not* template validation needs one.
- **`resources` on generated initContainers.** Neither `jinja-init` nor the validator sets any. Fine today; needed if a LimitRange or a ResourceQuota with `requests` enforcement ever lands.
- **Validation for the APIs' non-config templates.** None exist today. If an API ever mounts a template it does not itself parse, `validate` is already there for it.
- **Schema publication.** The UI validator images embed their schema. Nothing outside the image can answer "what does this app's config require?" — a `--print-schema` flag would let CI or a docs generator ask, and would make review of a values change easier.

---

## Alternatives considered

| Option | Verdict |
| --- | --- |
| **`templates.<name>.validate` generating an initContainer** | **Chosen.** The chart already knows the volume name, the file name and the app's image, so the values file states intent in one word and never touches chart internals. |
| Generic `apps.<name>.initContainers:` list | Rejected — a values file would have to reconstruct `<identifier>-tpl-out-<template>` from chart internals, and `identifier` is a truncated composite that may change. See decision 2. |
| Validator image named explicitly in every values file | Rejected as the default — a second field to bump on every release, and nothing enforces it matches the app. Kept as the map-form escape hatch. |
| Sidecar container validating continuously | Rejected — the rendered file lives in an emptyDir written once at pod start; it cannot change under a running pod. A permanent process to re-derive a constant. |
| Node runtime added to the nginx image, validating at entrypoint | Rejected in the requesting spec — no chart change needed, but a static file server would inherit a language runtime's CVE stream permanently. Contradicts the documented purpose of init containers. |
| Validate in CI, or in `helm unittest`, against the rendered template | Rejected — the ConfigMap holds Jinja2 *source*. What `{{ SECRET_UNIFI_API_KEY }}` resolves to exists only inside the pod, so CI cannot see the thing that breaks. |
| Chart-wide default `validate: true` | Rejected — it would immediately break the three APIs, which have no validator image and do not need one. Opt-in matches how probes, `annotations` and `strategy` already work in this chart. |
| Require every app to validate its own config instead | Rejected — correct for the APIs and impossible for nginx. Decision 1 keeps the invariant unified while letting the mechanism differ. |
