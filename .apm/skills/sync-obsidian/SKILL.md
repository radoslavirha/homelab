---
name: sync-obsidian
description: "Sync IoT services overview to Obsidian 'Server' folder for local network IoT device planning. Use whenever: changing service hostnames or IPs, bumping app image versions, adding/removing custom APIs or IoT services, changing Traefik external ports. Keeps Server/Homelab Overview.md accurate."
argument-hint: "Describe what changed, e.g. 'added new API' or 'changed EMQX hostname'"
---

# sync-obsidian

Reads current homelab IoT service state from the codebase and writes/updates `Server/Homelab Overview.md` in Obsidian. The note is for planning IoT devices on the local network — external access URLs, ports, auth hints. No internal Kubernetes details, no platform/infra services.

## When to Use

- Changing a service hostname or external IP
- Bumping a custom app image version
- Adding or removing a custom API (apps stage)
- Adding or removing an IoT service (EMQX, InfluxDB2, MongoDB)
- Changing Traefik external entrypoint ports

## Information to Extract

### IoT Services (server2)

**EMQX**
Source: `gitops/k8s-manifests/server2/emqx/HTTPRoute.yaml` (dashboard hostname), `gitops/helm-values/server2/traefik.yaml` (`ports.mqtt.exposedPort`, `service.externalIPs[0]`)
- Dashboard URL, MQTT TCP address (IP:port), auth note (credentials in OpenBao)

**InfluxDB2**
Source: `gitops/k8s-manifests/server2/influxdb2/HTTPRoute.yaml` (UI hostname), `gitops/helm-values/influxdb2.yaml` (`adminUser.organization`)
- UI URL, organisation, auth note (credentials in OpenBao)

**MongoDB**
Source: `gitops/helm-values/server2/traefik.yaml` (`ports.mongodb.exposedPort`, `service.externalIPs[0]`)
- External TCP address (IP:port), auth note

### Custom APIs (server2)

For each app in `gitops/argocd-manifests/apps/apps/` (skip `AppsOTelCollector`):

Source: `gitops/helm-values/apps/<app>/base.yaml` (image, component label, pathName), `gitops/helm-values/server2/apps/common/values.yaml` (`VAR_PUBLIC_DOMAIN`)

URL pattern:
- Production: `http://<component>.<VAR_PUBLIC_DOMAIN>/<partOf>/<pathName>` (when partOf non-empty, e.g. `iot`)
- Production: `http://<component>.<VAR_PUBLIC_DOMAIN>/<pathName>` (when partOf is empty)
- Sandbox: `http://sandbox.<component>.<VAR_PUBLIC_DOMAIN>/<partOf>/<pathName>` (when partOf non-empty)
- Sandbox: `http://sandbox.<component>.<VAR_PUBLIC_DOMAIN>/<pathName>` (when partOf is empty)
- UDP (if `udpIngress` present): `<externalIP>:<port>` from `gitops/helm-values/server2/traefik.yaml` ports

## Procedure

### 1. Identify Changed Sources

```bash
git diff --name-only HEAD~1
```

### 2. Read Affected Sources

For full refresh read all sources above. For targeted update read only changed files.

### 3. Overwrite Obsidian Note

Use `obsidian_append_content` to overwrite `Server/Homelab Overview.md` with the full note following the [template](./references/note-template.md).

**To overwrite an existing file**: first delete old content by using `obsidian_patch_content` with the existing top-level heading, then write the new full content with `obsidian_append_content`. OR if the file doesn't exist, just use `obsidian_append_content` directly.

Rules:
- Write the full note every time — no partial updates
- Frontmatter: `updated: <YYYY-MM-DD>` and `tags: [homelab, iot]`
- All URLs literal — no template variables
- External access only — no internal `*.svc.cluster.local` URLs
- Auth: one-line hint only ("credentials in OpenBao"), no secrets
- Skip: platform services (ArgoCD, Grafana, OpenBao UI), dashboards, network section, Telegraf

### 4. Verify

Use `obsidian_get_file_contents` to confirm write succeeded.

## Do NOT Change

- Any Obsidian note outside `Server/Homelab Overview.md`
- The `updated:` frontmatter format (agents parse it)
