# Reusable PostSync Provisioner Image

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `alpine:3.20` + `apk add --no-cache curl jq` in every PostSync Job with a purpose-built provisioner image that has `curl`, `jq`, and optionally `influx` CLI pre-installed. Eliminates the per-sync network call to the Alpine package registry (~5–10 s) and pins tooling versions explicitly.

**Current state:** Four PostSync Job YAMLs all start with the same boilerplate:
```yaml
image: alpine:3.20
command: ["/bin/sh", "-c"]
args:
  - |
    set -e
    apk add --no-cache curl jq > /dev/null
    ...
```
Files affected:
- `gitops/k8s-manifests/server2/influxdb2/provisioner-telegraf.yaml`
- `gitops/k8s-manifests/server2/emqx/provisioner-telegraf.yaml`
- `gitops/k8s-manifests/server2/emqx/provisioner-miot-bridge-production.yaml`
- `gitops/k8s-manifests/server2/emqx/provisioner-miot-bridge-sandbox.yaml`
- `gitops/k8s-manifests/server2/mongodb/provisioner-miot-bridge-production.yaml`
- `gitops/k8s-manifests/server2/mongodb/provisioner-miot-bridge-sandbox.yaml`

**Architecture:** A minimal Docker image built from Alpine with `curl` and `jq` baked in, published to GitHub Container Registry (`ghcr.io`). Built and pushed via a GitHub Actions workflow on changes to the `Dockerfile`. All PostSync Jobs switch to this image and drop the `apk add` line.

---

## Steps

### 1. Create the Dockerfile

- [ ] Create `provisioner/Dockerfile`:

```dockerfile
FROM alpine:3.21
RUN apk add --no-cache curl jq && rm -rf /var/cache/apk/*
SHELL ["/bin/sh", "-c"]
```

Keep it minimal — no entrypoint, no CMD. Jobs override with their own `command`/`args`.

### 2. Create the GitHub Actions build workflow

- [ ] Create `.github/workflows/provisioner-image.yaml`:

```yaml
name: Build provisioner image

on:
  push:
    paths:
      - "provisioner/Dockerfile"
    branches:
      - main
  workflow_dispatch:

env:
  IMAGE: ghcr.io/${{ github.repository_owner }}/homelab-provisioner

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: provisioner
          push: true
          tags: |
            ${{ env.IMAGE }}:latest
            ${{ env.IMAGE }}:${{ github.sha }}
```

### 3. Update all PostSync Job YAMLs

After the image is published, update each Job:

- [ ] `gitops/k8s-manifests/server2/influxdb2/provisioner-telegraf.yaml`
- [ ] `gitops/k8s-manifests/server2/emqx/provisioner-telegraf.yaml`
- [ ] `gitops/k8s-manifests/server2/emqx/provisioner-miot-bridge-production.yaml`
- [ ] `gitops/k8s-manifests/server2/emqx/provisioner-miot-bridge-sandbox.yaml`
- [ ] `gitops/k8s-manifests/server2/mongodb/provisioner-miot-bridge-production.yaml`
- [ ] `gitops/k8s-manifests/server2/mongodb/provisioner-miot-bridge-sandbox.yaml`

In each file, change:
```yaml
# Before
image: alpine:3.20
command: ["/bin/sh", "-c"]
args:
  - |
    set -e
    apk add --no-cache curl jq > /dev/null
    ...rest of script...
```
```yaml
# After
image: ghcr.io/radoslavirha/homelab-provisioner:latest
command: ["/bin/sh", "-c"]
args:
  - |
    set -e
    ...rest of script (no apk add line)...
```

Use the specific `${{ github.sha }}` tag in production if you want reproducible deployments. `latest` is fine for a homelab.

### 4. Pin the image SHA (optional hardening)

- [ ] After first push, update Jobs to use the digest:
```yaml
image: ghcr.io/radoslavirha/homelab-provisioner@sha256:<digest>
```
Retrieve digest with: `docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/radoslavirha/homelab-provisioner:latest`

Skip this step if `latest` tag is acceptable.

### 5. Verify

- [ ] Force-sync one of the updated apps (e.g., InfluxDB2 on server2).
- [ ] Confirm PostSync Job completes without `apk add` output in logs.
- [ ] Confirm idempotency: sync again, job skips all provisioning steps.

---

## Notes

- GHCR is free for public repos and free up to 500 MB/month for private. The image will be ~8 MB.
- Make the GHCR package public (`ghcr.io/<owner>/homelab-provisioner` → Package Settings → Change visibility) so cluster nodes can pull without credentials. Alternatively, add `imagePullSecrets` to the Job specs pointing at a GHCR token stored in OpenBao.
- Future: if provisioner scripts grow complex, consider splitting by target (influxdb2-provisioner, emqx-provisioner) with CLIs pre-installed (`influx` binary for InfluxDB2 provisioners).
