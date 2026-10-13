# Vantages — how to send traffic

## Contents

- V1 — laptop (full ingress path; single, burst, sustained)
- V2 — port-forward (Traefik removed)
- V3 — in-pod (preferred for anything about egress): residue rules, PodSecurity warning
- V4 — standalone pod (negative tests; orphan sweep)
- What the probe image can do (tools, substitutes for nc/dig)

Written against server2 on 2026-08-26. The apps moved to server1 on 2026-09-13; Service names,
pod labels, container names and the Cilium layout were re-checked on server1 on 2026-10-06.

Set the cluster first. Every vantage except V1 needs it:

```bash
export KUBECONFIG=iac/clusters/server1/credentials/kubeconfig
```

server1 is a **single-node** cluster, which is why `ds/cilium` and `exec ds/...` are unambiguous
here. That stops being true the moment a node is added.

---

## V1 — laptop

The full ingress path: laptop DNS → Unifi/ExternalDNS → Traefik (hostNetwork, `192.168.1.200` on
server1) → HTTPRoute → Service → pod.

```bash
RUN_ID="probe-$(date +%s)-$(head -c4 /dev/urandom | xxd -p)"
TRACE_ID=$(head -c16 /dev/urandom | xxd -p)
SPAN_ID=$(head -c8 /dev/urandom | xxd -p)

curl -sS -o /dev/null -m 10 \
  -w 'http=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
  -H "X-Probe-Run: $RUN_ID" \
  -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
  -A "homelab-probe/$RUN_ID" \
  "https://api.sandbox.server1.homelab.irha.cz/iot/interactive-map-feeder/data-sources/list?probe=$RUN_ID"
```

Expect `http=401` anonymously — see targets.md § Auth. Add
`-H "Authorization: Bearer $PROBE_TOKEN"` only when the handler must run.

Keep the trailing `?probe=$RUN_ID` — it lands in the Traefik `RequestPath` field, which makes
the run greppable in Loki even if header propagation ever regresses.

**Burst** (metrics need volume):

```bash
for i in $(seq 1 20); do
  curl -sS -o /dev/null -m 10 -w '%{http_code} ' \
    -H "X-Probe-Run: $RUN_ID" -H "traceparent: 00-${TRACE_ID}-$(head -c8 /dev/urandom | xxd -p)-01" \
    "https://api.sandbox.server1.homelab.irha.cz/iot/interactive-map-feeder/data-sources/list?probe=$RUN_ID"
done; echo
```

Note the **fresh span id per request** while the trace id stays fixed: all 20 requests join one
trace, which is what makes the burst findable as a unit.

**Sustained** (Hubble windows, rate-based PromQL) — run in the background so the lens can be
watched at the same time:

```bash
for i in $(seq 1 60); do
  curl -sS -o /dev/null -m 10 -H "X-Probe-Run: $RUN_ID" "https://api.sandbox.server1.homelab.irha.cz/iot/interactive-map-feeder/data-sources/list?probe=$RUN_ID"
  sleep 2
done
```

Fails when: the laptop is off the LAN, `*.server1.homelab.irha.cz` does not resolve (ExternalDNS or
the Unifi record is the suspect — check `dns=` in the `-w` output), or Traefik is down. `dns=` and
`connect=` in the timing output separate those three cases without any cluster access.

---

## V2 — port-forward

Traefik removed from the picture. Use to decide whether a failure is ingress or app.

```bash
kubectl port-forward -n sandbox svc/api-iot-interactive-map-feeder-api-http 8080:80 &
PF=$!
sleep 1
curl -sS -o /dev/null -m 10 -w 'http=%{http_code} total=%{time_total}s\n' \
  -H "X-Probe-Run: $RUN_ID" -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
  "http://127.0.0.1:8080/data-sources/list?probe=$RUN_ID"
kill $PF
```

**The path differs from V1.** Traefik strips the `/iot/interactive-map-feeder` prefix
(`stripPrefix: true`), so through the Service the app expects the bare path. Sending the
prefixed path here produces a 404 that means nothing.

Service names follow `<component>-<partOf>-<app>-<serviceRef>` inside each namespace, e.g.
`api-iot-interactive-map-feeder-api-http`. List them rather than guessing:
`kubectl get svc -n sandbox`.

---

## V3 — in-pod (preferred for anything about egress)

Injects an ephemeral container into the **running app pod** via `kubectl debug --target`,
sharing that pod's network namespace. Same Cilium identity, same DNS config, same policy
verdicts as the app itself. This is the only vantage whose answers about NetworkPolicy are
answers about the actual workload.

```bash
POD=$(kubectl get pod -n sandbox -l app.kubernetes.io/name=qr-manager-ui -o name | head -1)
CTR=apps-iot-qr-manager-ui   # the app container name, from `kubectl get $POD -n sandbox -o jsonpath='{.spec.containers[*].name}'`

kubectl debug -n sandbox $POD \
  --image=ghcr.io/radoslavirha/homelab-provisioner:latest \
  --target=$CTR --container=probe-$(date +%s) -q --attach=false \
  -- bash -c '
    echo "--- dns";  getent hosts mongodb.mongodb.svc.cluster.local emqx.iot.svc.cluster.local || echo "dns=FAIL"
    echo "--- tcp";  (timeout 5 bash -c "exec 3<>/dev/tcp/mongodb.mongodb.svc.cluster.local/27017" && echo "mongo27017=open") || echo "mongo27017=BLOCKED"
    echo "--- otlp"; curl -sS -o /dev/null -m 3 -w "alloy4318=%{http_code}\n" http://k8s-monitoring-alloy-receiver.monitoring.svc.cluster.local:4318/v1/traces
    echo DONE'
```

The container runs to completion. Find its name and read its output:

```bash
kubectl get -n sandbox $POD \
  -o jsonpath='{range .status.ephemeralContainerStatuses[*]}{.name}{"\t"}{.state}{"\n"}{end}'
kubectl logs -n sandbox ${POD#pod/} -c <probe-container-name>
```

If the status shows `waiting` with an image error, the probe never ran — that is not a network
result. Fix the image or name and run again.

### Residue — read this before using V3 on production

**An ephemeral container cannot be removed from a running pod.** It stays in the pod's status
for the pod's remaining life. Removing it means deleting or restarting the pod. Consequences:

- Prefer sandbox targets. Use production only when the question is specifically about production.
- The container name must be unique per pod — hence `--container=probe-$(date +%s)` above.
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

Sweep for orphans from interrupted runs first:

```bash
kubectl get pods -A -o name | grep -E '/probe-[0-9]+' || echo "no orphans"
```

```bash
kubectl run probe-$(date +%s) -n sandbox --rm -i --restart=Never \
  --image=ghcr.io/radoslavirha/homelab-provisioner:latest \
  --command -- bash -c '
    getent hosts opendata.chmi.cz || echo "extdns=FAIL"
    (timeout 5 bash -c "exec 3<>/dev/tcp/mongodb.mongodb.svc.cluster.local/27017" && echo "mongo=open") || echo "mongo=BLOCKED"'
```

`--rm` deletes the pod on exit.

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
| `timeout` | GNU coreutils | bound a `/dev/tcp` probe |
| `mongosh` | `/usr/bin/mongosh` | Mongo connectivity + read-back |
| `influx` | `/usr/local/bin/influx` | InfluxDB2 queries |
| `bao` | `/usr/local/bin/bao` | OpenBao |

**There is no `nc`, no `mosquitto_pub`, no `dig`.** Substitutes:

```bash
# TCP reachability — bounded, because a policy-denied path hangs instead of failing fast
(timeout 5 bash -c "exec 3<>/dev/tcp/HOST/PORT" && echo open) || echo BLOCKED

# UDP send (fire-and-forget — proves egress is permitted, not that anything received it)
bash -c "echo -n probe > /dev/udp/192.168.1.85/54321" && echo sent

# DNS
getent hosts NAME
```

`/dev/tcp` reports "open" for anything that completes a TCP handshake. On a policy-denied path it
hangs until a timeout rather than failing, which is why every TCP probe above runs under
`timeout 5`. GNU `timeout` exists in the image; it does **not** exist on the macOS host.
