# Obsidian Note Template — Server/Homelab Overview.md

Populate all fields from codebase. No internal Kubernetes URLs. No platform/infra services. External access only.

```markdown
---
updated: <YYYY-MM-DD>
tags: [homelab, iot]
---

# Homelab IoT Services

> Auto-generated — do not edit manually.

## EMQX — MQTT Broker

| | |
|-|-|
| Dashboard | http://mqtt.server2.home |
| MQTT TCP | 192.168.1.201:1883 |
| Auth | Credentials in OpenBao |

## InfluxDB2 — Time-Series Database

| | |
|-|-|
| UI | http://influx.server2.home |
| Organisation | homelab |
| Auth | Credentials in OpenBao |

## MongoDB

| | |
|-|-|
| TCP | 192.168.1.201:27017 |
| Auth | Credentials in OpenBao |

## Custom APIs

### miot-bridge-api

| | |
|-|-|
| Image | radoslavirha/miot-bridge:<tag> |
| Production HTTP | http://api.server2.home/iot/miot-bridge |
| Production UDP | 192.168.1.201:4000 |
| Sandbox HTTP | http://sandbox.api.server2.home/iot/miot-bridge |
| Sandbox UDP | 192.168.1.201:4001 |

### interactive-map-feeder-api

| | |
|-|-|
| Image | radoslavirha/interactive-map-feeder:<tag> |
| Production HTTP | http://api.server2.home/iot/interactive-map-feeder |
| Sandbox HTTP | http://sandbox.api.server2.home/iot/interactive-map-feeder |

### qr-manager-api

| | |
|-|-|
| Image | ghcr.io/radoslavirha/qr-manager-api:<tag> |
| Production HTTP | http://api.server2.home/iot/qr-manager |
| Sandbox HTTP | http://sandbox.api.server2.home/iot/qr-manager |
| Short URL | http://qr.home (→ production) |

### qr-manager-ui

| | |
|-|-|
| Image | ghcr.io/radoslavirha/qr-manager-ui:<tag> |
| Production HTTP | http://apps.server2.home/qr-manager |
| Sandbox HTTP | http://sandbox.apps.server2.home/qr-manager |
```

## Notes on Populating

- `<tag>` — read from `image.tag` in `gitops/helm-values/apps/<app>/base.yaml`
- URL path: `/<partOf>/<pathName>` when `partOf` non-empty; `/<pathName>` when `partOf` is empty
- If new API added: add section under "Custom APIs", same table format
- If hostname/IP changed: update the affected row
- Omit sandbox rows if app has no sandbox variant
