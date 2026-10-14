# Longhorn: drain stale instance-managers after an upgrade

## Contents

- Why the old instance-manager survives
- Checklist
- 1. Detect
- 2. Before touching anything
- 3. Detach, one cluster at a time
- 4. Side effects
- 5. Validate — repeat until clean

A Longhorn upgrade is not finished when `terraform apply` and the new pods are green. Every volume that
stayed attached through the upgrade keeps its engine in the **old** instance-manager (IM), and that IM
keeps a full `guaranteed-instance-manager-cpu` reservation (12% of node CPU by default) on top of the
new one. On 2026-10-14, after 1.11.1 → 1.12.1, server1 and server3 each carried a stale v1.11.1 IM for
weeks; server1 read 85% CPU requested on ~0.65 cores of real use.

## Why the old instance-manager survives

Live engine upgrade cannot start the new engine in the new IM while the volume is attached, so the
**old IM keeps running the new engine process until the volume fully detaches** (Longhorn 1.12.1 docs,
"Instance Manager Pods During Upgrade"). Longhorn removes the old IM by itself once no engine or
replica remains in it.

**A pod restart is not a detach.** On a single-node cluster the replacement pod lands on the same node,
the VolumeAttachment is kept, and the volume never detaches — server3 Grafana was restarted on
2026-09-22 and stayed on the old IM. Only cordon → delete → wait for `detached` works.

## Checklist

```
Stale IM cleanup:
- [ ] 1. Detection run on server1, server2, server3; stale IMs and their volumes listed
- [ ] 2. Operator agreed to the downtime; fresh dump-all.sh dump taken
- [ ] 3. Per cluster (server2 → server1 → server3): cordon → delete pods → all detached → uncordon
- [ ] 4. server3: OpenBao unsealed by the operator; one ExternalSecret per cluster force-synced
- [ ] 4. server1: miot-bridge subscriptions checked after EMQX restart
- [ ] 5. Detection re-run: one IM per node, NEW image, every volume attached + healthy
```

## 1. Detect

On every cluster — an IM whose image is not NEW and still lists engines is stale:

```bash
for c in server1 server2 server3; do
  echo "== $c"
  kubectl --context admin@$c -n longhorn-system get instancemanagers.longhorn.io -o json \
    | jq -r '.items[] | "\(.metadata.name) \(.spec.image) engines=\((.status.instanceEngines//{})|keys)"'
done
```

Volumes and pods to stop, for one stale IM (`<old-im>` from the output above):

```bash
ctx=admin@<cluster>
vols=$(kubectl --context $ctx -n longhorn-system get engines.longhorn.io -o json \
  | jq -r --arg im <old-im> '.items[] | select(.status.instanceManagerName==$im) | .spec.volumeName')
for v in $vols; do
  kubectl --context $ctx -n longhorn-system get volumes.longhorn.io $v -o json \
    | jq -r '.status.kubernetesStatus as $k | "\(.metadata.name) \($k.namespace) \([$k.workloadsStatus[]?.podName]|join(","))"'
done
# → pvc-…  emqx  emqx-0
```

No stale IM anywhere → done; skip the rest.

## 2. Before touching anything

Every listed pod goes down for 15–40 s, datastores included, and on server3 OpenBao seals. **Ask the
operator first**, and only proceed once they confirm they can unseal OpenBao now if server3 is on the
list. Then take a dump (AGENTS.md § Backups) — it needs OpenBao unsealed, so do it before, not after:

```bash
~/homelab-backups/dump-all.sh
```

## 3. Detach, one cluster at a time

Order server2 → server1 → server3, as for any platform change. Cordon only — **never `drain`**, which
would also evict the Longhorn and system pods.

```bash
node=$(kubectl --context $ctx get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl --context $ctx cordon $node
kubectl --context $ctx -n <ns> delete pod <pod>        # every pod from step 1; controllers recreate them Pending

# Poll until every volume from step 1 reads detached (took 15–40 s on 2026-10-14)
for v in $vols; do
  echo "$v $(kubectl --context $ctx -n longhorn-system get volumes.longhorn.io $v -o jsonpath='{.status.state}')"
done

kubectl --context $ctx uncordon $node
```

Uncordon only once **all** of them read `detached`. If one stays `attached` after a minute, a pod still
mounts it: re-run the `workloadsStatus` query from step 1 for that volume, delete what it lists, poll
again. Never uncordon early — the pods reattach to the old IM and the step has to be repeated.

## 4. Side effects

- **server3 OpenBao** comes back `Sealed=true`. Only the operator has the keys: **stop and wait for
  them** to run `kubectl exec -it -n openbao openbao-0 -- bao operator unseal` three times. Do not
  continue until `bao status` shows `Sealed false`.
- **ExternalSecrets** keep reading `SecretSynced` from before the seal. After the unseal, force one per
  cluster and confirm `status.refreshTime` moves past the unseal:
  ```bash
  kubectl --context admin@<cluster> -n <ns> annotate es <name> force-sync=$(date +%s) --overwrite
  kubectl --context admin@<cluster> -n <ns> get es <name> -o jsonpath='{.status.refreshTime}{"\n"}'
  ```
- **server1 EMQX** restart can leave miot-bridge connected with `subscriptions=0`. Check, and restart the
  bridge if so (production and sandbox alike). It flaps briefly while the old and new pod share a client
  id, then settles:
  ```bash
  kubectl --context admin@server1 -n iot exec emqx-0 -- emqx ctl clients list | grep -i miot
  kubectl --context admin@server1 -n <env> rollout restart deploy/api-iot-miot-bridge-api
  ```
- Loki, Tempo and the Authentik worker may sit not-ready for a few minutes after server3's volumes
  return. Wait before diagnosing them.

## 5. Validate — repeat until clean

Re-run the detection from step 1 on every cluster, plus the volume state:

```bash
kubectl --context $ctx -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness
```

Done means: **one IM per node, on the NEW image**, and every volume `attached` + `healthy`. If an old
IM is still listed, it still hosts an engine — find its volume with the step 1 query and repeat step 3
for that volume. Report the IM list and the node's CPU requested (`kubectl describe node` → Allocated
resources), which should drop by the reservation.
