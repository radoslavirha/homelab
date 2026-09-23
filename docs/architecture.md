# Architecture

Multi-cluster Kubernetes homelab: three Talos Linux nodes managed with a shared Terraform module library and a single GitOps repo.

## Cluster roles

| Cluster | Machine | Role |
|---------|---------|------|
| `server1` | server1 — 32 GB RAM / 6 cores / 500 GB SSD | Production workloads |
| `server2` | server2 — 32 GB RAM / 8 cores / 500 GB SSD | LLM engine since 2026-09-20 — its IoT estate was removed on 2026-09-13 and it now runs Ollama (CPU-only) and nothing else. Doubles as the canary: platform upgrades land here first |
| `server3` | server3 — 16 GB RAM / 4 cores / 500 GB SSD | Platform services — OpenBao, ArgoCD, Authentik, central observability hub (manages all clusters) |

## Technology stack

| Component | Purpose | Clusters | Managed by | Artifact Hub | Local values | Upstream `values.yaml` |
|-----------|---------|:--------:|------------|:------------:|-------------|------------------------|
| [Talos Linux](https://www.talos.dev/) | Immutable Kubernetes OS | all | Terraform `bootstrap` | — | — | — |
| [Cilium](https://docs.cilium.io/) | eBPF CNI, kube-proxy replacement, Hubble, Gateway API controller | all | Terraform `platform` | [cilium](https://artifacthub.io/packages/helm/cilium/cilium) | [shared](../iac/clusters/helm-values/cilium.yaml) · [server1](../iac/clusters/server1/helm-values/cilium.yaml) · [server2](../iac/clusters/server2/helm-values/cilium.yaml) · [server3](../iac/clusters/server3/helm-values/cilium.yaml) | [values.yaml](https://github.com/cilium/cilium/blob/main/install/kubernetes/cilium/values.yaml) |
| [Gateway API](https://gateway-api.sigs.k8s.io/) | Standard Kubernetes ingress/routing CRDs; installed before Cilium | all | Terraform `platform` | — | — | — |
| [Longhorn](https://longhorn.io/) | Distributed block storage | all | Terraform `platform` | [longhorn](https://artifacthub.io/packages/helm/longhorn/longhorn) | [shared](../iac/clusters/helm-values/longhorn.yaml) · [server1](../iac/clusters/server1/helm-values/longhorn.yaml) · [server2](../iac/clusters/server2/helm-values/longhorn.yaml) · [server3](../iac/clusters/server3/helm-values/longhorn.yaml) | [values.yaml](https://github.com/longhorn/longhorn/blob/master/chart/values.yaml) |
| [OpenBao](https://openbao.org/) | Secrets management; central backend for all clusters | server3 | Terraform `vault` | [openbao](https://artifacthub.io/packages/helm/openbao/openbao) | [server3](../iac/clusters/server3/helm-values/openbao.yaml) | [values.yaml](https://github.com/openbao/openbao-helm/blob/main/charts/openbao/values.yaml) |
| [ArgoCD](https://argoproj.github.io/cd/) | GitOps CD; manages workloads on all three clusters | server3 | Terraform `apps` | [argo-cd](https://artifacthub.io/packages/helm/argo/argo-cd) | [server3](../gitops/helm-values/server3/argocd.yaml) | [values.yaml](https://github.com/argoproj/argo-helm/blob/main/charts/argo-cd/values.yaml) |
| [Authentik](https://goauthentik.io/) | Identity provider serving `auth.irha.cz`; OIDC for every homelab application, human and machine; groups carry the roles APIs authorize on | server3 | ArgoCD `identity` | [authentik](https://artifacthub.io/packages/helm/goauthentik/authentik) | [server3](../gitops/helm-values/server3/authentik.yaml) | [values.yaml](https://github.com/goauthentik/helm/blob/main/charts/authentik/values.yaml) |
| authentik-blueprints | In-repo chart rendering the Authentik configuration graph — applications, providers, role groups, policy bindings — from one values matrix, plus two further blueprint files — onboarding (invitation-gated enrollment, admin-minted recovery) and login-surface hardening (no username enumeration, brute-force throttling, mandatory MFA); applied by Authentik's own worker | server3 | ArgoCD `identity` | — | [chart](../gitops/helm-charts/authentik-blueprints/) · [matrix](../gitops/helm-values/server3/authentik-blueprints.yaml) | — |
| [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | Cloudflare Tunnel: the WAN leg of the split horizon. One tunnel per cluster, dialled OUTBOUND (the house sits behind carrier NAT, so no inbound port exists). The ingress list in its ConfigMap **is** the public allow-list — a hostname absent from it is unreachable whatever DNS says, and the `http_status:404` catch-all is what keeps that true. Points at Traefik with `originServerName`, so every HTTPRoute, middleware and trace still applies. Raw manifests; the version is the image tag | server1, server3 | ArgoCD `gateway` | — | [server1](../gitops/k8s-manifests/server1/cloudflared/) · [server3](../gitops/k8s-manifests/server3/cloudflared/) · [appset](../gitops/argocd-manifests/apps/gateway/Cloudflared.yaml) · [reference](public-exposure.md) | — |
| [External Secrets Operator](https://external-secrets.io/) | Sync secrets from OpenBao; ClusterSecretStore per cluster | all | ArgoCD | [external-secrets](https://artifacthub.io/packages/helm/external-secrets-operator/external-secrets) | [shared](../gitops/helm-values/external-secrets.yaml) · [server3](../gitops/helm-values/server3/external-secrets.yaml) · [server2](../gitops/helm-values/server2/external-secrets.yaml) · [server1](../gitops/helm-values/server1/external-secrets.yaml) | [values.yaml](https://github.com/external-secrets/external-secrets/blob/main/deploy/charts/external-secrets/values.yaml) |
| [cert-manager](https://cert-manager.io/) | Issues the per-cluster wildcard TLS certificate from Let's Encrypt; ACME DNS-01 solved against Cloudflare, so a name needs no public reachability to be certified | all | ArgoCD | [cert-manager](https://artifacthub.io/packages/helm/cert-manager/cert-manager) | [shared](../gitops/helm-values/cert-manager.yaml) · [server1](../gitops/helm-values/server1/cert-manager.yaml) · [server2](../gitops/helm-values/server2/cert-manager.yaml) · [server3](../gitops/helm-values/server3/cert-manager.yaml) | [values.yaml](https://github.com/cert-manager/cert-manager/blob/master/deploy/charts/cert-manager/values.yaml) |
| [Stakater Reloader](https://github.com/stakater/Reloader) | Restart workloads annotated `reloader.stakater.com/auto` when a referenced ConfigMap/Secret changes (ESO credential rotation) | all | ArgoCD | [reloader](https://artifacthub.io/packages/helm/stakater/reloader) | [shared](../gitops/helm-values/reloader.yaml) · [server3](../gitops/helm-values/server3/reloader.yaml) · [server2](../gitops/helm-values/server2/reloader.yaml) · [server1](../gitops/helm-values/server1/reloader.yaml) | [values.yaml](https://github.com/stakater/Reloader/blob/master/deployments/kubernetes/chart/reloader/values.yaml) |
| [Traefik](https://traefik.io/) | Ingress / Gateway API proxy; hostNetwork bare-metal LB | all | ArgoCD | [traefik](https://artifacthub.io/packages/helm/traefik/traefik) | [shared](../gitops/helm-values/traefik.yaml) · [server3](../gitops/helm-values/server3/traefik.yaml) · [server2](../gitops/helm-values/server2/traefik.yaml) · [server1](../gitops/helm-values/server1/traefik.yaml) | [values.yaml](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml) |
| [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/) | Automatic DNS via UniFi webhook; sources: gateway-httproute, traefik-proxy, crd | all | ArgoCD | [external-dns](https://artifacthub.io/packages/helm/external-dns/external-dns) | [shared](../gitops/helm-values/external-dns.yaml) · [server3](../gitops/helm-values/server3/external-dns.yaml) · [server2](../gitops/helm-values/server2/external-dns.yaml) · [server1](../gitops/helm-values/server1/external-dns.yaml) | [values.yaml](https://github.com/kubernetes-sigs/external-dns/blob/master/charts/external-dns/values.yaml) |
| [Headlamp](https://headlamp.dev/) | Kubernetes web UI | all | ArgoCD | [headlamp](https://artifacthub.io/packages/helm/headlamp/headlamp) | [shared](../gitops/helm-values/headlamp.yaml) · [server3](../gitops/helm-values/server3/headlamp.yaml) · [server2](../gitops/helm-values/server2/headlamp.yaml) · [server1](../gitops/helm-values/server1/headlamp.yaml) | [values.yaml](https://github.com/kubernetes-sigs/headlamp/blob/main/charts/headlamp/values.yaml) |
| [Hubble UI](https://docs.cilium.io/en/stable/observability/hubble/) | Cilium network observability UI | all | ArgoCD | — | — | — |
| [Longhorn UI](https://longhorn.io/) | Distributed storage dashboard | all | ArgoCD | — | — | — |
| [MinIO](https://min.io/) | **Not deployed, and dropped as a backup destination.** Was intended as the S3 backend for both Terraform state and Longhorn backups. The Longhorn-backup half was abandoned in favour of offsite logical dumps to Cloudflare R2 (see "Why Longhorn on the server3 cluster?"); the Terraform-state half is still an open intention. No manifest and no ArgoCD Application exist | — | — | — | — | — |
| [MongoDB](https://www.mongodb.com/) | Document database | server1 | ArgoCD `databases` | [mongodb](https://artifacthub.io/packages/helm/bitnami/mongodb) | [shared](../gitops/helm-values/mongodb.yaml) · [server1](../gitops/helm-values/server1/mongodb.yaml) | [values.yaml](https://github.com/bitnami/charts/blob/main/bitnami/mongodb/values.yaml) |
| [EMQX](https://www.emqx.io/) | MQTT broker for IoT message routing | server1 | ArgoCD `iot` | [emqx](https://artifacthub.io/packages/helm/emqx/emqx) | [shared](../gitops/helm-values/emqx.yaml) · [server1](../gitops/helm-values/server1/emqx.yaml) | [values.yaml](https://github.com/emqx/emqx/blob/master/deploy/charts/emqx/values.yaml) |
| [InfluxDB2](https://www.influxdata.com/) | Time-series database for IoT data | server1 | ArgoCD `iot` | [influxdb2](https://artifacthub.io/packages/helm/influxdata/influxdb2) | [shared](../gitops/helm-values/influxdb2.yaml) · [server1](../gitops/helm-values/server1/influxdb2.yaml) | [values.yaml](https://github.com/influxdata/helm-charts/blob/master/charts/influxdb2/values.yaml) |
| [Telegraf](https://www.influxdata.com/time-series-platform/telegraf/) | MQTT consumer → InfluxDB2 writer; no inbound ports | server1 | ArgoCD `iot` | [telegraf](https://artifacthub.io/packages/helm/influxdata/telegraf) | [shared](../gitops/helm-values/telegraf.yaml) · [server1](../gitops/helm-values/server1/telegraf.yaml) | [values.yaml](https://github.com/influxdata/helm-charts/blob/master/charts/telegraf/values.yaml) |
| iot-infra | Raw manifests — carries the `provisioner` ServiceAccount into the `iot` namespace, the identity the PostSync provisioner Jobs log in to OpenBao with, before InfluxDB2 and EMQX sync | server1 | ArgoCD `iot` | — | [manifests](../gitops/k8s-manifests/server1/iot/) | — |
| provisioner | In-repo chart rendering the idempotent PostSync Jobs that create per-app datastore credentials and write them to OpenBao; added as an extra `sources` entry on each datastore ApplicationSet rather than deployed on its own. Image pinned by digest | server1 | ArgoCD `iot` · `databases` | — | [chart](../gitops/helm-charts/provisioner/) · [server1](../gitops/helm-values/server1/provisioner/) | — |
| network-policies | Default-deny plus the egress allow-list for `production` and `sandbox`; raw manifests, **manual-sync on purpose** so a rollback is not undone by `selfHeal` | server1 | ArgoCD `network-policies` | — | [manifests](../gitops/k8s-manifests/server1/network-policies/) | — |
| iot-applications | Shared Helm chart for custom IoT apps; supports multi-app deployments, Jinja2 config templates, secretRefs, optional Argo Rollouts | server1 | ArgoCD `apps` | — | [chart](../gitops/helm-charts/iot-applications/) | — |
| miot-bridge-api | MIOT device bridge API; HTTP ingress; MQTT + MongoDB; auto-provisioned credentials via PostSync Jobs | server1 | ArgoCD `apps` | — | [base](../gitops/helm-values/apps/miot-bridge-api/base.yaml) · [production](../gitops/helm-values/apps/miot-bridge-api/production.yaml) · [sandbox](../gitops/helm-values/apps/miot-bridge-api/sandbox.yaml) · [shared](../gitops/helm-values/apps/common/values.yaml) · [appset](../gitops/argocd-manifests/apps/apps/MiotBridgeApi.yaml) | — |
| interactive-map-feeder-api | Interactive map feeder API; HTTP ingress only; no secrets | server1 | ArgoCD `apps` | — | [base](../gitops/helm-values/apps/interactive-map-feeder-api/base.yaml) · [production](../gitops/helm-values/apps/interactive-map-feeder-api/production.yaml) · [sandbox](../gitops/helm-values/apps/interactive-map-feeder-api/sandbox.yaml) · [shared](../gitops/helm-values/apps/common/values.yaml) · [appset](../gitops/argocd-manifests/apps/apps/InteractiveMapFeederApi.yaml) | — |
| qr-manager-api | QR code redirect + admin CRUD API; HTTP ingress + `qr.irha.cz` shortcut; MongoDB for slug storage; auto-provisioned MongoDB credentials via PostSync Jobs | server1 | ArgoCD `apps` | — | [base](../gitops/helm-values/apps/qr-manager-api/base.yaml) · [production](../gitops/helm-values/apps/qr-manager-api/production.yaml) · [sandbox](../gitops/helm-values/apps/qr-manager-api/sandbox.yaml) · [shared](../gitops/helm-values/apps/common/values.yaml) · [appset](../gitops/argocd-manifests/apps/apps/QrManagerApi.yaml) | — |
| homelab-dashboard-ui | Homelab landing page (React + nginx) at `dashboard.server3.homelab.irha.cz`; rendered by the `iot-applications` chart; OIDC via Authentik | server3 | ArgoCD `server3/dashboards` | — | [server3](../gitops/helm-values/server3/homelab-dashboard-ui.yaml) | — |
| qr-manager-ui | QR code admin SPA (React + nginx); served at `apps.server1.homelab.irha.cz/qr-manager`; runtime `config.json` via ConfigMap subPath mount; no secrets | server1 | ArgoCD `apps` | — | [base](../gitops/helm-values/apps/qr-manager-ui/base.yaml) · [production](../gitops/helm-values/apps/qr-manager-ui/production.yaml) · [sandbox](../gitops/helm-values/apps/qr-manager-ui/sandbox.yaml) · [shared](../gitops/helm-values/apps/common/values.yaml) · [appset](../gitops/argocd-manifests/apps/apps/QrManagerUi.yaml) | — |
| [Mealie](https://mealie.io/) | Recipe manager and meal planner at `mealie.irha.cz` (apex tier); **trial**, LAN only. Authentik OIDC login only — local logins off since 2026-09-18 (confidential client, roles `mealie.admin`/`mealie.user`, accounts matched on `preferred_username`). Raw manifests — Mealie ships no official chart and is one container, so the version is the image tag in the Deployment, not a `targetRevision` | server1 | ArgoCD `household` | — | [manifests](../gitops/k8s-manifests/server1/mealie/) · [appset](../gitops/argocd-manifests/apps/household/Mealie.yaml) | — |
| mealie-postgres | PostgreSQL 17 backing Mealie, one replica inside the `mealie` namespace rather than a fleet-wide instance — a trial should not decide shared-database placement. Moving it later is a dump and a restore | server1 | ArgoCD `household` | — | [manifests](../gitops/k8s-manifests/server1/mealie/) | — |
| [Open WebUI](https://openwebui.com/) | The household assistant at `assistant.irha.cz` (apex tier), LAN only. General-purpose LLM chat front end and the future host for MCP tool servers and automations. Authentik OIDC only — the local login form is off and no local account was ever created (confidential client, roles `open-webui.admin`/`open-webui.user`; the first login bypasses role gating by design upstream). Model connections: the Ollama engine on server2, plus any cloud provider. Raw manifests, so the version is the image tag in the Deployment, not a `targetRevision` | server1 | ArgoCD `household` | — | [manifests](../gitops/k8s-manifests/server1/open-webui/) · [appset](../gitops/argocd-manifests/apps/household/OpenWebUI.yaml) | — |
| open-webui-postgres | PostgreSQL 17 **with `pgvector`** backing Open WebUI, one replica inside the `open-webui` namespace. Holds the app schema *and* the RAG embeddings (`VECTOR_DB=pgvector`), so there is one datastore to back up rather than a second on-disk vector store. The app issues `CREATE EXTENSION vector` itself on first use. `fsGroup` is 999, not Mealie's 70 — this image is Debian-based, not Alpine | server1 | ArgoCD `household` | — | [manifests](../gitops/k8s-manifests/server1/open-webui/) | — |
| [Ollama](https://ollama.com/) | CPU-only LLM inference engine at `ollama.server2.homelab.irha.cz`. **No authentication of any kind** — the protection is a Traefik `ipAllowList` middleware pinned to server1's node address, so Open WebUI reaches it and a laptop does not. Models are pulled by hand via `kubectl exec`, deliberately: a PostSync Job pulling 5–20 GB is long and fragile. Idle cost is ~0 — the model unloads after five minutes | server2 | ArgoCD `household` | — | [manifests](../gitops/k8s-manifests/server2/ollama/) · [appset](../gitops/argocd-manifests/apps/household/Ollama.yaml) | — |
| [Prometheus](https://prometheus.io/) | TSDB receiving OTLP metrics; no scraping (remote-write only) | server3 | ArgoCD `observability` | [prometheus](https://artifacthub.io/packages/helm/prometheus-community/prometheus) | [shared](../gitops/helm-values/prometheus.yaml) · [server3](../gitops/helm-values/server3/prometheus.yaml) | [values.yaml](https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/values.yaml) |
| [Grafana](https://grafana.com/) | Observability dashboards; datasources: Prometheus, Loki, Tempo, InfluxDB2 (server1). Authentik OIDC only — local logins off since 2026-09-21 (public client + PKCE, roles `grafana.admin`/`grafana.editor`/`grafana.reader`), and HTTP Basic is off on the API too, so provisioning reloads became pod restarts driven by Reloader — see [break-glass](observability.md#break-glass-getting-in-when-authentik-is-down) | server3 | ArgoCD `observability` | [grafana](https://artifacthub.io/packages/helm/grafana-community/grafana) | [shared](../gitops/helm-values/grafana.yaml) · [server3](../gitops/helm-values/server3/grafana.yaml) | [values.yaml](https://github.com/grafana-community/helm-charts/blob/main/charts/grafana/values.yaml) |
| [Loki](https://grafana.com/oss/loki/) | Log aggregation backend; ingest via the native OTLP endpoint `/otlp/v1/logs` (not the Loki push API) | server3 | ArgoCD `observability` | [loki](https://artifacthub.io/packages/helm/grafana-community/loki) | [shared](../gitops/helm-values/loki.yaml) | [values.yaml](https://github.com/grafana-community/helm-charts/blob/main/charts/loki/values.yaml) |
| [Tempo](https://grafana.com/oss/tempo/) | Distributed tracing backend; OTLP gRPC/HTTP receiver | server3 | ArgoCD `observability` | [tempo](https://artifacthub.io/packages/helm/grafana-community/tempo) | [shared](../gitops/helm-values/tempo.yaml) | [values.yaml](https://github.com/grafana-community/helm-charts/blob/main/charts/tempo/values.yaml) |
| [k8s-monitoring (Grafana Alloy)](https://grafana.com/docs/k8s-monitoring) | Infrastructure + app observability; cluster/host/pod metrics, logs, events; OTLP receiver (alloy-receiver); server3: fan-out to Prometheus (remote-write), Loki (native OTLP) and Tempo (OTLP gRPC); server1/server2: forward all signals to otel.server3.homelab.irha.cz:4317 | server1 · server2 · server3 | ArgoCD `observability` (AppSet) | [k8s-monitoring](https://artifacthub.io/packages/helm/grafana/k8s-monitoring) | [shared](../gitops/helm-values/k8s-monitoring.yaml) · [server1](../gitops/helm-values/server1/k8s-monitoring.yaml) · [server2](../gitops/helm-values/server2/k8s-monitoring.yaml) · [server3](../gitops/helm-values/server3/k8s-monitoring.yaml) | [values.yaml](https://github.com/grafana/k8s-monitoring-helm/blob/main/charts/k8s-monitoring/values.yaml) |

## Hostnames and TLS

Every service is reachable over HTTPS with a publicly-trusted certificate, on a LAN-only name.
Those two facts are independent: proving control of a *name* (ACME DNS-01, a TXT record at
Cloudflare) is not the same as the *service* being reachable, so `vault.server3.homelab.irha.cz`
holds a real Let's Encrypt certificate while resolving only on `192.168.1.0/24` and having no
port forward. No private CA, no per-device trust store, no browser warnings.

**Two naming tiers.** Infrastructure lives under a reserved subtree; the apex is kept free for
names that are, or may become, publicly reachable.

| Tier | Shape | Members |
|------|-------|---------|
| Infrastructure | `<svc>.<cluster>.homelab.irha.cz` | everything, by default |
| Apex | `<svc>.irha.cz` | **Published to the internet 2026-09-22:** `auth.irha.cz` (Authentik, server3), `grafana.irha.cz` (server3), `mealie.irha.cz` (server1). **Apex-named but LAN-only:** `qr.irha.cz`, `assistant.irha.cz`. Publishing is per name and opt-in — see [public-exposure.md](public-exposure.md) |

App routes generated by the `iot-applications` chart follow the same rule, with the stage label
left of the component: `api.server1.homelab.irha.cz` for production,
`api.sandbox.server1.homelab.irha.cz` for sandbox. That ordering means sandbox is not a
subdomain of production — cookie scope, HSTS `includeSubDomains` and wildcard-scoped policy stop
leaking across the boundary — and one wildcard covers a whole stage rather than one per
component.

**One certificate per cluster**, in that cluster's `traefik` namespace so a Gateway listener's
`certificateRefs` resolve without a `ReferenceGrant`:

| Cluster | `dnsNames` | Secret |
|---------|-----------|--------|
| server1 | `server1.homelab.irha.cz`, `*.server1.homelab.irha.cz`, `*.sandbox.server1.homelab.irha.cz`, `qr.irha.cz`, `mealie.irha.cz`, `assistant.irha.cz` | `server1-tls` |
| server2 | `server2.homelab.irha.cz`, `*.server2.homelab.irha.cz`, `*.sandbox.server2.homelab.irha.cz` | `server2-tls` |
| server3 | `server3.homelab.irha.cz`, `*.server3.homelab.irha.cz`, `auth.irha.cz`, `grafana.irha.cz` | `server3-tls` |

A certificate wildcard matches exactly one label (RFC 6125), which is why the four-label sandbox
names need their own SAN. A *DNS* wildcard matches at any depth (RFC 4592) — the two are spelled
alike and behave differently.

server2's sandbox SAN currently matches nothing — that cluster has had no `sandbox` namespace since
its IoT estate was removed on 2026-09-13. It is carried rather than dropped so a future workload
needs no certificate reissue.

**Split horizon.** ExternalDNS writes A records to UniFi and only to UniFi, so LAN clients and
cluster nodes get `192.168.1.x`. cert-manager writes `_acme-challenge` TXT records to Cloudflare
and only during issuance — created, validated, deleted, roughly 90 seconds. The two never touch
the same records, and the public zone holds nothing between renewals. Nodes resolve via
`192.168.1.1` (DHCP-derived); cert-manager deliberately does not, running with
`dns01RecursiveNameserversOnly` so its self-check bypasses the LAN view.

**LAN-exposed TCP.** Traefik runs `hostNetwork: true`, so every entrypoint is bound directly on
the node IPs — what is defined in `ports:` is what the LAN can reach.

| Port | Cluster | State |
|------|---------|-------|
| 443 | all | TLS, cluster certificate |
| 80 | all | plaintext, no redirect — see below |
| 27017 MongoDB | server1 | **TLS only**, terminated at Traefik against the cluster certificate; `mongod` itself is untouched. Compass connects with `?tls=true` |
| 1883 MQTT | server1 | plaintext, authenticated |
| 8883 MQTTS | server1 | TLS, same broker behind it |
| 4317 OTLP gRPC | server3 | **TLS**, terminated at Traefik; unauthenticated |
| 4000-4001 | server1 | UDP, miot |

server2 opens 443 and 80 only. Its `ports:` block was removed on 2026-09-13 with the IoT estate —
every TCP/UDP entrypoint above routed to nothing once the `IngressRouteTCP` objects went.

Both MQTT ports stay open on purpose. TLS termination selects the router by the SNI the client
sends, and it is not established that the Loxone Miniserver and the ESP32 devices can do MQTT
over TLS with SNI — several ESPHome and Arduino MQTT clients cannot. Closing 1883 before that is
known would take the IoT estate offline. Authentication and ACLs are enforced on both
(`EMQX_AUTHORIZATION__NO_MATCH: deny`), so the exposure on 1883 is the credential travelling in
the clear inside the CONNECT packet, not unauthenticated access.

OTLP gRPC is encrypted but still unauthenticated. Traefik terminates TLS against the cluster
certificate and forwards plaintext h2c to `alloy-receiver` — gRPC without TLS *is* h2c, so the
receiver needs no certificate of its own. What that does not do is prove who is connecting:
anything on the LAN that speaks TLS can still inject telemetry. Authentication needs mTLS,
because the receiving end has never validated a bearer token — k8s-monitoring exposes no
server-side OTLP auth, so sending one would authenticate nothing while looking like it did.

**Accepted, not pending (decided 2026-09-23).** The risk is injection, not disclosure: a
misconfigured or compromised LAN device writing junk telemetry. The LAN's untrusted population is
ESP devices, there is no inbound path from the internet, and the OTLP/HTTP route
(`otel.server3.homelab.irha.cz`) is just as open, so an allow-list on 4317 alone would close
nothing. Revisit only if one of these becomes true: an untrusted device joins the LAN, a guest or
IoT VLAN gets routed to the cluster subnet, the endpoint is exposed beyond the LAN, or a second
site sends telemetry over a link you do not control. At that point the options are a Traefik
`ipAllowList` on **both** OTLP paths (cheap, authenticates an address), or mTLS. mTLS is real
identity, but nothing here renews client certificates, so every renewal becomes a manual step.

Port 80 also still serves — there is no blanket 80 → 443 redirect, because ESPHome devices on
the LAN fetch over plain HTTP and may not follow one.

**The Traefik API is not exposed.** `api.insecure` is `false`; with `hostNetwork` it would put
the API and dashboard on `:8080` of every node with no authentication, handing out every
hostname, backend and middleware in the cluster. The dashboard is reachable only through its
IngressRoute on `websecure`.

## ServiceAccounts

Each backend API has a dedicated Kubernetes ServiceAccount (preparation for future API-to-API authentication with projected tokens, mTLS, or gRPC):

| Service | ServiceAccount Name | Environment | Namespace | Scope |
|---------|-------------------|-------------|-----------|-------|
| miot-bridge-api | `api-iot-miot-bridge-api` | production / sandbox | `production` / `sandbox` | server1; receives MQTT messages and stores in MongoDB |
| interactive-map-feeder-api | `api-iot-interactive-map-feeder-api` | production / sandbox | `production` / `sandbox` | server1; feeds map state from external sources |
| qr-manager-api | `api-iot-qr-manager-api` | production / sandbox | `production` / `sandbox` | server1; manages QR code shortcuts and stores in MongoDB |

All ServiceAccounts have `automountServiceAccountToken: false` — tokens are not auto-mounted. When API-to-API communication is enabled, projected tokens will be mounted on-demand via the Deployment spec.

## Multi-cluster design decisions

### Why Terraform for bootstrap + platform + ArgoCD install (server3 only)?

These components must exist before ArgoCD can function. Installing them with ArgoCD creates a chicken-and-egg dependency. Terraform manages them directly; ArgoCD self-manages its own Helm release after first install (via the self-management Application).

ArgoCD is installed only on the server3 cluster and manages all three clusters. The server1 and server2 clusters do not run their own ArgoCD instance.

### Why OpenBao on the server3 cluster, managed by Terraform?

OpenBao is a prerequisite for External Secrets Operator across all clusters. If ArgoCD managed OpenBao, ESO couldn't sync secrets needed to start ArgoCD's own apps — a circular dependency. Managing it via Terraform (same as Longhorn) solves this. The server3 cluster is the trust anchor.

### Why Longhorn on the server3 cluster?

Longhorn provides durable PersistentVolumes for OpenBao. The overhead (≈500 MB RAM, single replica) is acceptable on server3's 16 GB.

**There are no Longhorn-level backups, but there are offsite logical dumps.** Keep the two apart — they fail differently.

*Longhorn side, unchanged:* `backupTarget` is `""` in [longhorn.yaml](../iac/clusters/helm-values/longhorn.yaml), the `default` BackupTarget reports `available: false` on all three clusters, and there are zero RecurringJobs, Backups and Snapshots fleet-wide. The CSI snapshotter is not installed, so `VolumeSnapshot` is not a served resource. **There is no volume-level restore and no point-in-time snapshot of a PVC.**

*What does exist, since 2026-09-07:* `~/homelab-backups/dump-all.sh` takes application-level dumps and uploads them to Cloudflare R2 (~300 MB), checksummed under `SHA256SUMS` and pruned on a retention window. It is run by hand, not scheduled — so its freshness is only ever as good as the last run.

| Cluster | Covered by the offsite dumps | **Not** covered |
|---|---|---|
| server1 | InfluxDB2 25Gi · MongoDB 10Gi · etcd | EMQX 20Mi · Mealie data 10Gi · Mealie PostgreSQL 5Gi · Open WebUI data 20Gi · Open WebUI PostgreSQL 10Gi |
| server2 | etcd | Ollama models 100Gi — re-pullable from upstream, so deliberately excluded |
| server3 | OpenBao 10Gi (raft snapshot) · Authentik PostgreSQL 10Gi · etcd | Prometheus 20Gi · Loki 20Gi · Tempo 20Gi · Grafana 5Gi |

The server3 exclusions are deliberate: Prometheus, Loki and Tempo hold reconstructible telemetry, and Grafana is fully provisioned from git. EMQX's 20Mi is broker runtime state, not configuration.

Mealie's and Open WebUI's four volumes are the gap that is *not* deliberate — they are simply newer than the script. Both databases are a plain `pg_dump` away from fitting the path that already dumps Authentik's PostgreSQL, and the two data volumes (recipe images; uploads and RAG source documents) need a file copy. Adding all four to `~/homelab-backups/dump-all.sh` is an open follow-up; until then, recipes and chat history exist on one disk only.

Every PVC is still single-replica on one node, so a lost disk still loses the volume — the dumps are a rebuild path, not high availability.

The originally intended design was Longhorn `backupTarget` pointing at MinIO on the same cluster, which is why MinIO appears in the bootstrap notes. **That was dropped, not deferred** — same-cluster backups would not survive the node, which is exactly the failure these single-control-plane clusters are most exposed to. Offsite dumps replaced it; do not re-propose MinIO as a backup destination.

Stated so it is not rediscovered under pressure: any Longhorn or Talos upgrade, and any OpenBao upgrade, is currently a one-way door. Take a manual snapshot or dump first — there is nothing to roll back to.

### Why not ArgoCD hub-spoke now?

Hub-spoke is the design from day one: ArgoCD runs only on the server3 cluster and manages workloads on all three clusters via registered external clusters.

Bootstrap order:
1. Server3 cluster is provisioned and ArgoCD is installed via Terraform
2. Server1 and server2 clusters are provisioned (bootstrap + platform only via Terraform)
3. Their kubeconfigs are registered in server3 ArgoCD
4. ArgoCD deploys all apps to server1 and server2 via ApplicationSets

### Why a single GitOps repo for all clusters?

With one operator (you), there is no access control requirement that mandates separation. A single `gitops/` directory with `clusters/<name>/` subdirectories reduces cross-repo coordination friction and makes it easy to share charts and values. ArgoCD Applications scope themselves to the correct subdirectory via `path:`.

### IaC vs GitOps separation (two top-level directories in this repo)

Terraform code (IaC) and ArgoCD content (GitOps) are separated at the directory level, not at the repo level. This gives clean separation of concerns while keeping related content co-located. ArgoCD is scoped to `gitops/` via `path:` in Application manifests and never syncs anything from `iac/`.

### Why no Terraform remote backend initially?

MinIO is the intended S3-compatible backend for Terraform state, and would itself be deployed by ArgoCD on the server3 cluster. That chicken-and-egg is why the server3 cluster's TF state starts as local files and would migrate once MinIO is operational. **MinIO has not been deployed**, so all state is still local for every cluster and the migration described in [iac.md](iac.md#state-backend-migration-to-minio) has not been performed.

## Bootstrap sequence

```
┌─────────────────────────────────────────────────────────────────────────┐
│ SERVER3 CLUSTER                                                         │
│                                                                         │
│  1. terraform bootstrap  → Talos cluster + credentials                  │
│  2. terraform platform   → Cilium + Longhorn + Gateway API              │
│  3. terraform vault      → OpenBao                                      │
│     [manual: OpenBao init ceremony, unseal, KV path setup]              │
│  4. terraform apps       → ArgoCD                                       │
│  5. ArgoCD GitOps — two kubectl applies on server3:                     │
│     a. kubectl apply ArgoCD.yaml     → ArgoCD self-management           │
│     b. kubectl apply Bootstrap.yaml  → meta App-of-Apps over roots/     │
│        wave 1  RootInfra            (ESO + CRDs)                        │
│        wave 2  RootGateway          (Traefik + ExternalDNS)             │
│        wave 2  server3/RootDashboards (OpenBao HTTPRoute, dashboard UI) │
│        wave 3  RootObservability    (k8s-monitoring)                      │
│        wave 3  server3/RootObservability (Prometheus, Grafana, Loki, Tempo) │
│        wave 3  RootIoT              (InfluxDB2, EMQX, Telegraf, IotInfra)│
│        wave 3  RootDatabases        (MongoDB)                           │
│        wave 3  RootDashboards       (Headlamp, Hubble, Longhorn)        │
│        wave 3  server3/RootIdentity (Authentik + authentik-blueprints)  │
│        wave 4  RootApps             (miot-bridge, interactive-map-feeder, qr-manager-api, qr-manager-ui) │
│        wave 4  RootHousehold        (Mealie, Open WebUI + their        │
│                                      PostgreSQL; Ollama on server2)     │
│        wave 5  RootNetworkPolicies  (default-deny + egress allow-list)  │
│     [manual: terraform init -migrate-state for all server3 modules]     │
│  6. terraform vault-config → OpenBao auth: OIDC login via Authentik     │
│     [after RootIdentity is healthy and the blueprint has landed;        │
│      manual: copy the client secret from Authentik into KV first]       │
│  7. Register server1 + server2 kubeconfigs in server3 ArgoCD            │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ SERVER1 / SERVER2 CLUSTER                                               │
│                                                                         │
│  1. terraform bootstrap  → Talos cluster + credentials                  │
│  2. terraform platform   → Cilium + Longhorn + Gateway API              │
│     (no apps stage — ArgoCD on server3 manages this cluster)            │
│  3. Single OpenBao session — all vault work before any ArgoCD sync:     │
│     a. Collect token reviewer JWT from new cluster                      │
│     b. Register Kubernetes auth mount (one per cluster)                 │
│     c. ESO read-only policy + role                                      │
│     d. Provisioner write policy + long-lived token → OpenBao KV        │
│     e. Seed all KV secrets (external-dns, plus influxdb2/emqx/mongodb  │
│        only on a cluster that runs them — server1 today)               │
│     See docs/iac.md step 3 for full commands.                           │
│  4. Register kubeconfig in server3 ArgoCD                               │
│  5. Add cluster to ApplicationSet list generators, commit               │
│     → server3 ArgoCD deploys: ESO → Traefik → Headlamp (+ EMQX,        │
│       InfluxDB2, MongoDB and the IoT apps only where listed — server1) │
└─────────────────────────────────────────────────────────────────────────┘
```

## ArgoCD hub-spoke

ArgoCD runs only on the server3 cluster and manages workloads on all three clusters. There are no per-cluster ArgoCD instances.

- server3 ArgoCD manages `server3`, `server1`, and `server2` via registered external clusters
- `destination.server` in Application manifests selects which cluster each app deploys to
- ApplicationSets can template apps across clusters
- Destroying/rebuilding server1 or server2 does not affect GitOps state (it lives on server3)

Post-bootstrap steps for each new cluster:
1. Register its kubeconfig in server3 ArgoCD (`argocd cluster add`)
2. Apply the cluster's ApplicationSets / Application manifests from `gitops/`

## Identity and access

Authentik on server3 is the single identity provider — `auth.irha.cz`. Every human login and every
machine identity goes through it, and every API authorizes on the `roles` claim of a token it minted.

The whole configuration graph is generated, not clicked: one values matrix at
[`gitops/helm-values/server3/authentik-blueprints.yaml`](../gitops/helm-values/server3/authentik-blueprints.yaml)
renders an Application, an OAuth2 provider, one group per role and one policy binding per group, for
every application **in every environment** — including a `local` environment whose redirect URIs are
loopback, so a developer machine mimics a deployment instead of borrowing sandbox's client.

Roles form a per-application ladder (`admin` → `editor` → `reader`) expressed as Authentik group
parentage, so a user in the `-admin` group alone receives all three roles in the claim and an API can
set one role as a class-level floor.

Entries carry a `kind`: `api` (the default — a human's browser logs in), `client` (`postman`, which a
human drives against several APIs at once), or `device` (a machine using `client_credentials`, with a
service account the blueprint declares). The two non-`api` kinds name the APIs they may call and render a single client spanning every
environment they list, so one login yields one token valid at every API. The roles claim is `app.role`
with no environment in it, so that token carries the union of the holder's roles across those
environments.

See [docs/identity.md](identity.md) for the object model, naming, token shape, the role ladder, and
how to add an application or a role.

## Observability

Central LGTM stack on server3 — metrics (Prometheus), logs (Loki), traces (Tempo), dashboards (Grafana). OTel push endpoints: `http://otel.server3.homelab.irha.cz` (HTTP/4318 via HTTPRoute) and `otel.server3.homelab.irha.cz:4317` (gRPC via IngressRouteTCP).
See [docs/observability.md](observability.md) for full architecture, pipeline details, and datasource correlations.

## Secret management

Secrets flow: OpenBao (server3 cluster) → ESO ClusterSecretStore → Kubernetes Secrets.

- OpenBao KV path layout: `secret/<cluster>/<app>/<key>`
- Each cluster has an ESO `ClusterSecretStore` pointed at server3 OpenBao (HTTPS over LAN)
- No secrets are committed to the repo — all live in OpenBao, read by Terraform via the vault provider

OpenBao initialization is a manual ceremony performed once after the server3 secrets stage.
Steps are fully documented in [docs/iac.md](iac.md) under "Bootstrap sequence — Server3 cluster" (step 3).
