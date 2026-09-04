# MQTT ACLs — verify what was shipped

**Status:** open. The work is believed done; **nothing has confirmed it against a running cluster.**

**Parent:** [`../plans/2026-08-29-mqtt-topic-acls.md`](../plans/2026-08-29-mqtt-topic-acls.md) — the
implementation brief, with the verified client and topic inventory, the draft rule set and the rollout
cautions.

**Independent of the Authentik work.** No application code, no shared files.

---

## What happened

`EMQX_AUTHORIZATION__NO_MATCH: deny` was set on 2026-08-30 and per-user ACLs are provisioned into the
built-in database. Before that, `no_match = allow` and `acl.conf` ended `{allow, all}.` — so the
per-client credentials that already existed bought nothing: any authenticated client could publish to
another device's command topic or subscribe to everything.

It is tracked as an open problem in `iot-miniservers` → `docs/superpowers/OPEN-THREADS.md` #1, and stays
open there until someone confirms it.

## What to confirm

- `emqx ctl conf show authorization` actually reports `no_match = deny` on the running broker, on
  **both** server1 and server2.
- A client can publish to its own topic space and is refused elsewhere. A live negative test is the
  point; the config being present is not the same as it being enforced.

## The blocker to check first

**Loxone's MQTT username is not in GitOps.** A `deny` default with no rule for it silently kills the
live integration — no error at the broker, just a device that stops working. If verification shows the
default is enforced, check Loxone before anything else, and get its username into GitOps either way.

## Why it is worth doing now

It is a one-command answer to a row that has been sitting open on an assumption, and if the assumption
is wrong the failure mode is silent. Most device traffic here is MQTT, so this is where most device
authorization actually lives.
