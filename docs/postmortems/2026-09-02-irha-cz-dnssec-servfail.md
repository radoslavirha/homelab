# `irha.cz` was DNSSEC-broken and failed to resolve publicly

**Status:** fixed 2026-09-02 at the registrar. One record.
**Found:** while verifying assumptions before requesting the first Let's Encrypt certificate.
**Affects:** every name in `irha.cz`, from every validating resolver on the internet. The LAN was
never affected, which is exactly what made it hard to see.

## Summary

Every DNSSEC-validating resolver returned `SERVFAIL` for **every** name in the zone:

```
dig A irha.cz @1.1.1.1            ->  SERVFAIL
dig A irha.cz @8.8.8.8            ->  SERVFAIL
dig A irha.cz @9.9.9.9            ->  SERVFAIL
dig +cd +short A irha.cz @1.1.1.1 ->  100.67.147.18     # +cd disables validation
```

The zone data was fine. Only the chain of trust was broken — which is why `+cd` answered and
everything else did not.

| Where | What it published |
|-------|-------------------|
| `.cz` parent, from the registrar | `DS 2366 8 2 97A3C3C7…` — keytag 2366, algorithm **8** (RSASHA256) |
| `irha.cz` zone, from Cloudflare | `DNSKEY 257 3 13 …` — keytag 2371, algorithm **13** (ECDSAP256SHA256) |

Neither the key tag nor the algorithm matched. The DS at the registrar pointed at a key that no
longer existed in the zone — the signature of a nameserver migration to Cloudflare where the
registrar's DS was never updated. A validator sees "this zone claims to be signed, and the
parent's proof does not fit," and the only correct response to that is `SERVFAIL`.

## Why it was invisible from the LAN

UniFi answers names in this zone from **local overrides**, returned ahead of any upstream query
and therefore ahead of any validation. Every check from a machine on the LAN passed while the
zone was globally unresolvable. The split horizon works — it simply cannot help a resolver with
no local record, which is every resolver on the internet.

## Why it would have blocked TLS entirely

Let's Encrypt validates DNSSEC. Boulder resolves `_acme-challenge.<name>` through a validating
resolver, gets `SERVFAIL`, and fails the challenge — no certificate could ever have issued for
any name in this zone. cert-manager's own DNS-01 self-check fails first and identically, because
it is pointed at `1.1.1.1` by `--dns01-recursive-nameservers`. The `Certificate` sits `Pending`
and the error reads like a cert-manager or API-token problem. It is neither.

## The fix

**The algorithm field is the whole bug.** The stale entry was RSA/SHA-256 (algorithm 8);
Cloudflare signs with ECDSA P-256 (algorithm 13). Re-picking an RSA option reproduces the fault
exactly.

Wedos asks for the **DNSKEY**, not the DS, and derives the DS itself:

| Field | Value |
|-------|-------|
| Flag | `257` — KSK / SEP. The zone's other key, `256 …`, is the ZSK and does not go here |
| Protocol | `3` |
| Algorithm | **`13` — ECDSAP256SHA256** |
| Key | the KSK from Cloudflare → DNS → Settings → DNSSEC |

Replace the old entry rather than adding beside it. `dig` line-wraps the base64 key; it is one
unbroken string.

If a registrar's dropdown has no algorithm 13, **delete** the DNSSEC entry instead: an unsigned
delegation validates as *insecure* rather than *bogus*, so resolution recovers and ACME works.
Worse than a correct DS, better than a broken one.

Propagation took minutes, though the `.cz` DS TTL is 3600s — allow an hour before treating a
failure as real.

## Verifying

```bash
# NOERROR from a validating resolver, with the `ad` (authenticated data) flag set:
dig +dnssec A irha.cz @1.1.1.1 | grep -E 'status:|flags:'

# The differential that proves it is DNSSEC and not something else. While broken the first
# line SERVFAILs and the second answers; once fixed, both answer:
dig +short A irha.cz @1.1.1.1
dig +cd +short A irha.cz @1.1.1.1

# Parent DS matches the zone's KSK:
dig +short DS irha.cz @a.ns.nic.cz
dig +short DNSKEY irha.cz @demi.ns.cloudflare.com | grep '^257'
```

Do not reach for `delv` on macOS — the system build reports `no crypto support` and validates
nothing. [dnsviz.net](https://dnsviz.net/) is the readable second opinion.

## Lesson

A zone can be perfectly healthy on the LAN and completely unresolvable everywhere else, and no
check that runs from inside the network will ever show it. Any work that depends on a public
resolver — ACME above all — should verify against `1.1.1.1` or `8.8.8.8` directly before
assuming DNS is fine.
