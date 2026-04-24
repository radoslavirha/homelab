# OTel Gateway Bearer Token Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Secure the OTel Gateway ingestion endpoints on server3 with bearer token authentication so only authorised cluster forwarders (server2, future server1) can push telemetry.

**Architecture:** A shared bearer token is stored in OpenBao (`secret/otel-gateway/auth-token`), synced to both server3 and server2 via ESO as a K8s Secret, and injected into the OTel collector pods as an env var. The server3 receiver validates the token via the `bearertokenauth` extension; server2 sends it as an `Authorization` header on the `otlp_grpc/server3` exporter.

**Tech Stack:** OpenBao KV v2, External Secrets Operator, `otel/opentelemetry-collector-contrib` (`bearertokenauth` extension), ArgoCD GitOps.

---

### Future: token rotation

Rotation is explicitly deferred. When addressed, options are:

1. **KV v2 + ESO refresh** — write a new version of `secret/otel-gateway/auth-token` in OpenBao; ESO picks it up within `refreshInterval` (1h). The OTel pod will need a rolling restart because `extraEnvsFrom` bakes env vars at pod start. To avoid downtime, switch to a volume-mounted file and use the `bearertokenauth.filename` config key instead of `token`.

2. **AppRole + `vaultauth` extension** — replace `bearertokenauth` with the OTel `vaultauth` authenticator. Short-lived tokens are fetched directly from OpenBao by the collector. No ESO required for the token itself.
