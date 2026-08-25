# `homelab-dashboard-ui` — Unifi Credential Behind nginx: homelab side

**Scope:** this repository only — `gitops/helm-values/server3/homelab-dashboard-ui.yaml`. **No chart change is needed** (verified, see [The `secretRefs` role change](#the-secretrefs-role-change)).

**Companion spec:** [`iot-miniservers` → `docs/superpowers/specs/2026-08-08-dashboard-credential-boundary.md`](../../../../iot-miniservers/docs/superpowers/specs/2026-08-08-dashboard-credential-boundary.md) — path relative to a sibling checkout of `radoslavirha/iot-miniservers`. It carries the reasoning (why a browser cannot hold a secret, why nginx is the BFF here, why the fail-fast property has to move out of the config validator) and owns every application-side change. This plan is the values half only.

**Goal:** the Unifi API key stops being served to the browser in `/config.json`. nginx attaches it to the proxied request instead, from an env var that never leaves the pod.

**Status:** the values half is applied in the working tree — `env: UNIFI_HOST` added, `unifi.host` and `unifi.apiKey` removed from `templates.config.content`. It needs the matching `image.tag` bump to go out with it — see [One coordinated change](#one-coordinated-change).

---

## The env var contract

The app image reads exactly two variables in its main nginx container:

| Variable | Source in values | Consumed by | Was |
| --- | --- | --- | --- |
| `UNIFI_HOST` | `env:` (plain value) | nginx `proxy_pass ${UNIFI_HOST}/proxy/network/;` | derived from `config.json` by `docker-entrypoint.d/10-derive-unifi-host.envsh` — that hook is **deleted** by the app-side change |
| `SECRET_UNIFI_API_KEY` | `secretRefs` → `envFrom` | nginx `proxy_set_header X-Api-Key "${SECRET_UNIFI_API_KEY}";` | the **jinja-init** container, substituted into `config.json` as `unifi.apiKey` |

Both are substituted into `nginx.conf.template` by the image's stock `20-envsubst-on-templates.sh`. A new app-side entrypoint hook, `10-require-unifi-env.sh`, fails the container fast (non-zero exit, value never echoed) if either is empty.

After the change, the runtime Zod schema's `unifi` object is `{ site }` only. `title`, `serverPattern`, `scheme`, `exclude` and `paths` are untouched.

> **Debugging caveat, inherited from the spec:** `nginx -T` inside this pod prints the rendered config **including the API key**. That output is sensitive — do not paste it into an issue or a chat.

---

## What this actually closes

Worth being precise about, because it is what motivated dropping the rollout gate.

The ConfigMap in git only ever held the **placeholder** `"apiKey": "{{ SECRET_UNIFI_API_KEY }}"`. The real value is substituted by the jinja-init container into an emptyDir, and *that* rendered file is what nginx mounts at `/usr/share/nginx/html/config.json` and serves. So the credential has been readable by anything that could open the dashboard — view-source, devtools, `curl http://dashboard.home/config.json` — the entire time, while looking harmless in the repository.

**Removing those two fields from `templates.config.content` is what closes the exposure — not the image tag bump.** The new image stops the *browser* from needing the key; deleting it from the served file is what stops the key being handed out. Until this change is deployed, it is still being served on every page load.

---

## One coordinated change

**Backwards compatibility is explicitly not required here.** The repo owner has accepted brief downtime for this dashboard, so the earlier three-step contract dance is dropped. The values change and the `image.tag` bump apply **together, in one ArgoCD sync**:

- [ ] Confirm both images exist at the new tag: `ghcr.io/radoslavirha/homelab-dashboard-ui` **and** `ghcr.io/radoslavirha/homelab-dashboard-ui-config-validator`. The chart derives the validator image from `image.repository` + `-config-validator` + `image.tag`; a missing validator tag is an `Init:ImagePullBackOff`, not a config error.
- [ ] Bump `image.tag` in `gitops/helm-values/server3/homelab-dashboard-ui.yaml` in the **same commit** as the config-content change already staged there.
- [ ] Sync and watch. The dashboard has **no sandbox** — this rolls the live dashboard on server3 directly.

### The accepted failure mode

`annotations: reloader.stakater.com/auto: "true"` restarts the pod when the ConfigMap changes. If that restart lands while the **old** image is still what the Deployment references — ArgoCD applies the ConfigMap and the Deployment in the same sync, but the ordering between "Reloader notices the ConfigMap" and "the new ReplicaSet is up" is not something this repo controls — then the old validator image runs against the new config, finds no `unifi.apiKey`, and **fails init**. The pod does not start.

That is understood and accepted. `maxUnavailable: 0` means the failure is contained rather than destructive: it stalls, it does not corrupt anything, and the next reconcile with the new image resolves it. **The dashboard may be down for a few minutes.** That is fine, and it is the trade being made in exchange for not staging this across three deploys.

If it does stall, there is nothing to fix — confirm the Deployment is on the new tag and let it retry. `kubectl logs <pod> -c homelab-dashboard-ui-config-validate` will show the old validator's schema error, which is the expected symptom rather than a new problem.

---

## The `secretRefs` role change

`secretRefs` itself **does not change**. Its role does:

```yaml
    secretRefs:
      - name: homelab-dashboard-ui-unifi-credentials
        keys:
          - SECRET_UNIFI_API_KEY
```

- **Before:** consumed by the jinja-init container as `JINJA_VAR_SECRET_UNIFI_API_KEY`, substituted into `config.json`.
- **After:** consumed by the **main nginx container** via `envFrom`, and attached to the upstream request by `proxy_set_header`.

**Verified against the chart, 2026-08-25 — no chart change is needed. Do not go looking for one.**

| Check | Where | Result |
| --- | --- | --- |
| Main container gets the secret as env | `gitops/helm-charts/iot-applications/templates/deployment.yaml:196-203` | yes — `envFrom: [{secretRef: {name: …}}]` for every entry in `secretRefs`, unconditionally |
| Same for the Rollout path | `templates/rollout.yaml:172-178` | yes, identical (this app uses the Deployment path, but the two do not drift) |
| jinja-init still gets it | `templates/deployment.yaml:117-126` | yes — `JINJA_VAR_<key>` via `secretKeyRef`, driven by `secretRefs[].keys` |
| `env:` reaches the main container | `templates/deployment.yaml:204-207` | yes — `toYaml $application.env`, any valid Kubernetes env entry |
| The env var lands under the exact name nginx expects | `gitops/k8s-manifests/server3/homelab-dashboard-ui/ExternalSecret.unifi.yaml` | yes — the ExternalSecret's `secretKey` is `SECRET_UNIFI_API_KEY` |

That last row is the one worth understanding: `envFrom.secretRef` injects **every key in the Secret** under its own name, and ignores `secretRefs[].keys` — that list only drives the jinja-init `JINJA_VAR_*` block. So what the nginx container sees is dictated by the ExternalSecret's `secretKey`, not by the values file. It is `SECRET_UNIFI_API_KEY` today, which is exactly the name the nginx template substitutes.

Confirmed by rendering the real values stack:

```
          envFrom:
            - secretRef:
                name: homelab-dashboard-ui-unifi-credentials
          env:
            - name: UNIFI_HOST
              value: https://192.168.1.1
```

---

## `validate: true` stays

`templates.config.validate: true` remains meaningful and stays on.

`config.json` still carries required fields — `serverPattern`, `scheme`, and `unifi.site` — so the validating initContainer still catches an empty or malformed substitution before the pod serves anything. What it loses is coverage of the **credential**: once `apiKey` is an env var, the schema cannot see it, and an empty secret would boot a happy-looking pod that 401s on every Unifi request.

That fail-fast property does not disappear; it moves to the app's own `docker-entrypoint.d/10-require-unifi-env.sh`, which refuses to start on an empty `UNIFI_HOST` or `SECRET_UNIFI_API_KEY`. Two guards, two files, one property — removing `validate: true` would drop the half that still applies.

---

## Verification

Once the sync has settled:

- [ ] `curl http://dashboard.home/config.json` — still valid JSON, still has `serverPattern` / `scheme` / `unifi.site`.
- [ ] The dashboard renders DNS records. That is the proof the key reached the upstream, since Unifi 401s without it.
- [ ] In devtools, the request to `/proxy/network/...` carries **no** `X-Api-Key` from the browser.
- [ ] `kubectl logs` for the pod contains neither value; the entrypoint prints only the "configuration present" line.

- [ ] `curl http://dashboard.home/config.json | grep -E 'apiKey|host'` — **no match**. This is the assertion that matters; everything else is the dashboard still working.
- [ ] Validator initContainer `Completed exit=0` against the new config.

---

## Rotate the key afterwards

- [ ] Rotate `server3/homelab-dashboard-ui-unifi` → `api-key` in OpenBao once this change is deployed and verified.

Until this lands, the key is in a file nginx serves publicly, so **the current value must be considered disclosed** — by anything that could reach the dashboard, regardless of whether anyone actually looked. Fixing the architecture does not un-disclose the value that was exposed under it. Rotation is what closes that, and it comes *after* the deploy rather than before only because rotating first would just publish the new value in the same served file.

The ExternalSecret refreshes hourly (`refreshInterval: 1h`) and the Reloader annotation restarts the pod when the synced Secret changes, so the rotation needs no manual restart — but confirm the restart happened rather than assuming it.

---

## Out of scope

- **Authenticating the dashboard itself.** Nothing authenticates a visitor today, and this does not change that — a visitor now uses the proxy instead of the key. Identity-aware proxy work is tracked separately.
- **Narrowing `/proxy/network/` to the endpoints the app actually calls.** Real hardening, but it belongs with the authentication work.
