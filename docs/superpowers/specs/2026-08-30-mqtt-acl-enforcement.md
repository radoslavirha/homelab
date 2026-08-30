# MQTT ACL enforcement — audit, then flip

**Status:** step 1 done and deployed (`ac902a4`). Step 2 (audit) written, awaiting sync. Step 3
(enforcement) not taken. **Nothing is enforced yet.**

Scope of this spec: the two config keys in
[`gitops/helm-values/emqx.yaml`](../../../gitops/helm-values/emqx.yaml) —
`EMQX_rule_engine__rules__AUTHZ_AUDIT` and `EMQX_AUTHORIZATION__NO_MATCH`. Everything else is
already in git and applied.

---

## What is already true

- Authn and authz both use EMQX's **built-in database**. One source, verified live on server1 and
  server2: `{"sources":[{"enable":true,"max_rules":100,"type":"built_in_database"}]}`.
- The stock `file` source is **gone**. It shipped an acl.conf ending `{allow, all}.`, which would have
  matched everything ahead of any rule and made the flip below a no-op.
- Rules for the three provisioned users are applied and verified on both clusters — `telegraf` (1
  rule), `miot-bridge-production` (3), `miot-bridge-sandbox` (3) — provisioned per username from
  `users[].acl` in `gitops/helm-values/<cluster>/provisioner/emqx.yaml`.
- `loxone` and `explorer` are hand-made accounts; their rules are added by the owner through the
  dashboard, in the same source. A sync never touches usernames absent from values.
- **`authorization.no_match = allow`.** Every client can still publish and subscribe anywhere,
  exactly as before this work. The rules are staged, not active.

---

## Step 2 — audit (written, needs a sync)

`$events/client_check_authz_complete` fires on every authorization decision and carries
`authz_source`: the source that decided it, **empty when nothing matched and the `no_match` default
decided**. While `no_match` is `allow`, an empty source is precisely a check that `deny` would break.

The rule prints each decision through the console action. EMQX's console handler defaults to
`warning`, which would swallow it, so `EMQX_LOG__CONSOLE__LEVEL: info` is set alongside — the two are
a pair and are reverted together. Alloy already ships the broker's stdout to Loki, so evidence
accumulates with nobody watching.

```
{k8s_pod_name="emqx-0", k8s_cluster_name="server1"} |= "authz_audit"
```

Both clusters are covered; swap `k8s_cluster_name` for server2.

**Why not MQTT + InfluxDB.** The obvious sink was a republish to `iot/_authz_audit` consumed by
telegraf. It needs a new bucket, a new scoped token (the existing telegraf token is write-scoped to
`loxone` alone, and the provisioner skips token creation when one already exists in OpenBao), an
ExternalSecret, a second telegraf output, and an ACL grant so telegraf may subscribe the audit topic.
Writing into the existing `loxone` bucket instead would feed string tags to the `Downsample Loxone`
task's `aggregateWindow(fn: mean)` and break it. The broker log costs none of that.

### Exit criteria

Let it run through a **full cycle of real traffic** — a vacuum run, a command from Loxone, a telegraf
write. Then, per cluster:

1. Every distinct `username` seen in the audit is one of: `telegraf`, `miot-bridge-production`,
   `miot-bridge-sandbox`, `loxone`, `explorer`. **An unexpected username is a blocker** — it means a
   client nobody inventoried is connected, and it dies at the flip.
2. No line has an empty `authz_source`. Every check resolves through `built_in_database`.
3. `loxone`'s own checks resolve — proof the hand-added rules are right, which nothing in git can
   verify.

Both `1` and `2` must hold on **both** clusters before step 3.

---

## Step 3 — flip

Uncomment one line in [`gitops/helm-values/emqx.yaml`](../../../gitops/helm-values/emqx.yaml):

```yaml
  EMQX_AUTHORIZATION__NO_MATCH: deny
```

`recreatePods: true` means this rolls the broker. Then remove `AUTHZ_AUDIT` and
`EMQX_LOG__CONSOLE__LEVEL` — EMQX's docs call the console action a debugging tool that costs
performance in production, and info-level logging is noisier than this broker normally runs.

**Verification must prove a message arrived, not that a connection succeeded.** A wrong ACL does not
error: the client stays connected, looks healthy, and silently publishes nothing. "MQTT connected" has
already proven useless as a signal here.

- change a MiOT device property → the value reaches Loxone
- publish a command from Loxone → the device acts
- a new point lands in the InfluxDB `loxone` bucket via telegraf
- `emqx ctl clients list` — `delivered_msgs` still climbing per client

Denials log as `authorization_permission_denied` with `tag: AUTHZ`, so after the flip:

```
{k8s_pod_name="emqx-0"} |= "authorization_permission_denied"
```

**Rollback** is re-commenting the line and syncing; the broker rolls back to `allow` and every client
works again. Cheap, and worth using at the first sign of a silent client rather than debugging under
enforcement.

---

## Known gaps

- **`loxone` and `explorer` exist only in mnesia** — accounts *and* rules. A rebuild on a fresh PVC
  loses both, and once `no_match = deny` is live that means Loxone is silently dead until recreated by
  hand. Neither password is in OpenBao, so neither can be rebuilt from git. Fixing it is credential
  provisioning: add them to `users[]` with a `baoPath`, at the cost of re-entering a generated
  password in the Miniserver once. Their rules then move into values with them.
- **On a fresh cluster the broker is fail-closed until the provisioner finishes.** With the flip live,
  no client is authorized until the PostSync Jobs apply the rules. Safe by default, but a failed
  provisioner sync means dead IoT rather than an open broker.
- **Removing a user from values leaves orphan rules** on the broker. `PUT` converges a username's
  rules but nothing deletes a username that disappears from git. The provisioner does not delete
  accounts either, so this is not a new class of drift.
