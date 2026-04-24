# Source Map — Obsidian Sync

## EMQX

- Dashboard hostname: `gitops/k8s-manifests/server2/emqx/HTTPRoute.yaml` → `spec.hostnames[0]`
- MQTT external IP: `gitops/helm-values/server2/traefik.yaml` → `service.externalIPs[0]`
- MQTT TCP port: `gitops/helm-values/server2/traefik.yaml` → `ports.mqtt.exposedPort`

## InfluxDB2

- UI hostname: `gitops/k8s-manifests/server2/influxdb2/HTTPRoute.yaml` → `spec.hostnames[0]`
- Organisation: `gitops/helm-values/influxdb2.yaml` → `adminUser.organization`

## MongoDB

- External IP: `gitops/helm-values/server2/traefik.yaml` → `service.externalIPs[0]`
- External TCP port: `gitops/helm-values/server2/traefik.yaml` → `ports.mongodb.exposedPort`

## Custom APIs

For each app in `gitops/argocd-manifests/apps/apps/` (skip `AppsOTelCollector`):

- Image repo + tag: `gitops/helm-values/apps/<app>/base.yaml` → `apps.<key>.image.repository` + `.tag`
- Component (subdomain): `gitops/helm-values/apps/<app>/base.yaml` → `apps.<key>.labels.component`
- HTTP path: `gitops/helm-values/apps/<app>/base.yaml` → `apps.<key>.ingress.pathName`
- Public domain: `gitops/helm-values/server2/apps/common/values.yaml` → `VAR_PUBLIC_DOMAIN`
- UDP prod port: `gitops/helm-values/server2/traefik.yaml` → `ports.udp-miot-prod.port` (if `udpIngress` present)
- UDP sandbox port: `gitops/helm-values/server2/traefik.yaml` → `ports.udp-miot-sbx.port`
- External IP: `gitops/helm-values/server2/traefik.yaml` → `service.externalIPs[0]`
