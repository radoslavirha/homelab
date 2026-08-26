# Vantages — how to send traffic

All commands verified against server2 on 2026-08-26 unless marked otherwise.

Set the cluster first. Every vantage except V1 needs it:

```bash
export KUBECONFIG=iac/clusters/<cluster>/credentials/kubeconfig
```

Both server1 and server2 are **single-node** clusters, which is why `ds/cilium` and
`exec ds/...` are unambiguous here. That stops being true the moment a node is added.

---

## V1 — laptop

The full ingress path: laptop DNS → Unifi/ExternalDNS → Traefik (hostNetwork, `192.168.1.201`
on server2) → HTTPRoute → Service → pod.

```bash
RUN_ID="probe-$(date +%s)-$(head -c4 /dev/urandom | xxd -p)"
TRACE_ID=$(head -c16 /dev/urandom | xxd -p)
SPAN_ID=$(head -c8 /dev/urandom | xxd -p)

curl -sS -o /dev/null \
  -w 'http=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
  -H "X-Probe-Run: $RUN_ID" \
  -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
  -A "homelab-probe/$RUN_ID" \
  "http://api.server2.home/iot/interactive-map-feeder/v1/data-sources/list?probe=$RUN_ID"
```

Keep the trailing `?probe=$RUN_ID` — it lands in the Traefik `RequestPath` field, which makes
the run greppable in Loki even if header propagation ever regresses.

**Burst** (metrics need volume):

```bash
for i in $(seq 1 20); do
  curl -sS -o /dev/null -w '%{http_code} ' \
    -H "X-Probe-Run: $RUN_ID" -H "traceparent: 00-${TRACE_ID}-$(head -c8 /dev/urandom | xxd -p)-01" \
    "http://api.server2.home/iot/interactive-map-feeder/v1/data-sources/list?probe=$RUN_ID"
done; echo
```

Note the **fresh span id per request** while the trace id stays fixed: all 20 requests join one
trace, which is what makes the burst findable as a unit.

**Sustained** (Hubble windows, rate-based PromQL) — run in the background so the lens can be
watched at the same time:

```bash
for i in $(seq 1 60); do
  curl -sS -o /dev/null -H "X-Probe-Run: $RUN_ID" "http://api.server2.home/iot/interactive-map-feeder/v1/data-sources/list?probe=$RUN_ID"
  sleep 2
done
```

Fails when: the laptop is off the LAN, `*.server?.home` does not resolve (ExternalDNS or the
Unifi record is the suspect — check `dns=` in the `-w` output), or Traefik is down. `dns=` and
`connect=` in the timing output separate those three cases without any cluster access.

---

## V2 — port-forward

Traefik removed from the picture. Use to decide whether a failure is ingress or app.

```bash
kubectl port-forward -n production svc/api-iot-interactive-map-feeder-api-http 8080:80 &
PF=$!
curl -sS -o /dev/null -w 'http=%{http_code} total=%{time_total}s\n' \
  -H "X-Probe-Run: $RUN_ID" -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
  "http://127.0.0.1:8080/v1/data-sources/list?probe=$RUN_ID"
kill $PF
```

**The path differs from V1.** Traefik strips the `/iot/interactive-map-feeder` prefix
(`stripPrefix: true`), so through the Service the app expects the bare path. Sending the
prefixed path here produces a 404 that means nothing.

Service names follow `<ns>-<component>-<partOf>-<app>-<serviceRef>`. List them rather than
guessing: `kubectl get svc -n production`.

---

## V3 — in-pod (preferred for anything about egress)

Injects an ephemeral container into the **running app pod** via `kubectl debug --target`,
sharing that pod's network namespace. Same Cilium identity, same DNS config, same policy
verdicts as the app itself. This is the only vantage whose answers about NetworkPolicy are
answers about the actual workload.

```bash
POD=$(kubectl get pod -n sandbox -l app.kubernetes.io/name=qr-manager-ui -o name | head -1)
CTR=apps-iot-qr-manager-ui   # the app container name, from `kubectl get pod $POD -o jsonpath='{.spec.containers[*].name}'`

kubectl debug -n sandbox $POD \
  --image=ghcr.io/radoslavirha/homelab-provisioner:latest \
  --target=$CTR --container=probe -q --attach=false \
  -- bash -c '
    echo "--- dns";  getent hosts mongodb.mongodb.svc.cluster.local emqx.iot.svc.cluster.local || echo "dns=FAIL"
    echo "--- tcp";  (bash -c "exec 3<>/dev/tcp/mongodb.mongodb.svc.cluster.local/27017" && echo "mongo27017=open") || echo "mongo27017=BLOCKED"
    echo "--- otlp"; curl -sS -o /dev/null -m 3 -w "alloy4318=%{http_code}\n" http://k8s-monitoring-alloy-receiver.monitoring.svc.cluster.local:4318/v1/traces
    echo DONE'

kubectl logs -n sandbox ${POD#pod/} -c probe
```

The container runs to completion; read its output with `kubectl logs -c probe`. Check it
actually started:

```bash
kubectl get pod -n sandbox ${POD#pod/} \
  -o jsonpath='{range .status.ephemeralContainerStatuses[*]}{.name}{"\t"}{.state}{"\n"}{end}'
```

### Residue — read this before using V3 on production

**An ephemeral container cannot be removed from a running pod.** It stays in the pod's status
for the pod's remaining life. Removing it means deleting or restarting the pod. Consequences:

- Prefer sandbox targets. Use production only when the question is specifically about production.
- The container name must be unique per pod — reusing `probe` on the same pod fails. Use
  `--container=probe-$(date +%s)` on repeat runs against one pod.
- To clean up, delete the pod (`kubectl delete pod -n <ns> <pod>`), which the controller
  recreates. Routine per AGENTS.md, but it is a restart: brief unavailability at `replicas: 1`,
  and the app loses its warm state.

### The PodSecurity warning is expected

`kubectl debug` emits a `Warning: would violate PodSecurity "restricted:latest"` block. It is a
**warning, not an enforcement** — the container starts. Do not "fix" it with
`--profile=restricted`: that sets `runAsNonRoot=true` and the provisioner image runs as root,
so the probe would refuse to start.

---

## V4 — standalone pod

A pod with labels you choose. Its value is the **negative test**: proving that something which
should not have access does not have it. Also the right vantage when the target pod has no
suitable container to attach to.

```bash
kubectl run probe-$(date +%s) -n sandbox --rm -i --restart=Never \
  --image=ghcr.io/radoslavirha/homelab-provisioner:latest \
  --command -- bash -c '
    getent hosts opendata.chmi.cz || echo "extdns=FAIL"
    (bash -c "exec 3<>/dev/tcp/mongodb.mongodb.svc.cluster.local/27017" && echo "mongo=open") || echo "mongo=BLOCKED"'
```

`--rm` deletes the pod on exit. Sweep for orphans from interrupted runs at the start of any
session that uses V4:

```bash
kubectl get pods -A -o name | grep -E '/probe-[0-9]+' || echo "no orphans"
```

To make the probe pod carry an app's labels (so a label-selecting policy applies to it), add
`--labels='app.kubernetes.io/name=...'`. This produces a pod with the app's *labels* but not
necessarily its full Cilium identity — V3 remains the accurate vantage for identity-based
verdicts.

---

## What the probe image can do

`ghcr.io/radoslavirha/homelab-provisioner:latest` — debian bookworm-slim. Verified contents:

| Tool | Path | Use |
|---|---|---|
| `curl` | `/usr/bin/curl` | HTTP, timings, headers |
| `jq` | `/usr/bin/jq` | response parsing |
| `bash` | `/usr/bin/bash` | `/dev/tcp` and `/dev/udp` probes |
| `mongosh` | `/usr/bin/mongosh` | Mongo connectivity + read-back |
| `influx` | `/usr/local/bin/influx` | InfluxDB2 queries |
| `bao` | `/usr/local/bin/bao` | OpenBao, for when endpoints get authenticated |

**There is no `nc`, no `mosquitto_pub`, no `dig`.** Substitutes:

```bash
# TCP reachability
(bash -c "exec 3<>/dev/tcp/HOST/PORT" && echo open) || echo BLOCKED

# UDP send (fire-and-forget — proves egress is permitted, not that anything received it)
bash -c "echo -n probe > /dev/udp/192.168.1.85/54321" && echo sent

# DNS
getent hosts NAME
```

`/dev/tcp` reports "open" for anything that completes a TCP handshake, so on a policy-denied
path it hangs until the shell's own timeout rather than failing fast. Wrap long probes in
`timeout 5 bash -c '...'` inside the container (GNU `timeout` is present in the image;
it is **not** present on the macOS host).
