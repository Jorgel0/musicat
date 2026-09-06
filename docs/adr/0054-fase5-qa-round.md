# 0054 — Fixing what Fase 5's QA found (and one thing I got wrong)

## Context
After Fase 5 shipped, Jorge asked for a bug hunt and an honest design
critique. Both came back with real material, and I verified every serious
claim against the source myself before acting: four issues filed
(#10–#13), plus a critic's list of which the top items were confirmed by
reading and reproducing.

Two patterns caused most of it, and fixing them as patterns rather than as
separate patches is what this round is:

**(a) I made the tombstone too absolute.** Jorge's rule was that no later
*sync* may resurrect a removal. I wrote it into the briefs as "nothing may
ever", and it grew into a trap: accepting a friend request from someone
you once removed silently no-op'd (the service said 200, the UI said "you
are now friends", nothing happened locally), and a re-add could not cancel
an already-queued revocation. **An explicit user action is not a sync.**

**(b) Login silently created an account for any typo**, which is the root
of both the second-account lockout (#11) and the case-sensitivity trap.

## Decision
- **Explicit actions now forget a removal.** A new
  `FriendStore.forgetRemoval`, called only from the accept and send
  routes; `addFromAccountService` is left unweakened so background syncs
  still refuse a tombstoned account, and every rule-2 test still passes
  unchanged. Re-adding also cancels a queued revocation (#10) — wired at
  the route, which already owns both collaborators, so `FriendStore`
  stays network-free.
- **A device acts for one account at a time** (#11). Logging in as a
  different account unlinks the device from every other. Safe, because it
  needs the target account's password *and* a signature from the device.
  Logout stays purely local — it works offline and deliberately keeps
  your friends.
- **Usernames are canonically lower-case**; two pre-existing accounts
  differing only by case are detected and reported (`409`), never merged
  or shadowed.
- **Account creation is opt-in on the wire** (`allowCreate`, defaulting
  to `true`), so the app can ask before creating. Minimum password length
  of 8, on creation only.
- **Every login failure now carries a machine-readable `code`** beside
  the human message.
- Per-source-address creation limit (10/hour, checked before the Argon2
  hash), and `LoginNonceStore` now sweeps.
- **App: the default-relay mechanism exists but ships no value** — see
  below.

## Consequences

### The relay default is built and deliberately empty
The critic's headline was that on a fresh install none of Fase 5 is
reachable: no compiled-in relay, an empty "Relay URL (optional)" field,
and the account service derived from it — so a new user signs in, gets a
generic failure, and has no way to know what to do. I confirmed it by
grepping: there is no default anywhere.

**In the brief for that fix I invented a hostname** rather than looking
one up — a plausible-looking `wss://relay.musicat.ictel.com/connect` that
does not exist. I caught it before it landed and corrected the agent; it
had already declined to hardcode it. Recording the mistake because the
failure mode (a fabricated value that reads as researched) is worth
recognising.

The real value is a decision for Jorge, not a lookup: the only deployment
recorded (ADR 0035) is a bare home IP over plain `ws://` with no DNS name.
Baking that into a public repo publishes his home address forever, breaks
every install at once if the IP changes, and ships without TLS. So the
whole mechanism is built and tested — one constant in
`app/lib/core/embedded_server/default_relay.dart`, "a stored value always
wins", "empty means use the default", and the default never written into
saved config — with the constant left empty.

What did improve regardless: the dead end is gone. A build with no relay
now says so plainly, explains what to do, and says that invite codes and
QR still work.

### The one I got wrong myself
Issue #12: `mergeFriendDevices` was meant to prefer a locally-learned
relay and fall back to the authoritative one. I reviewed that line, said
it was "exactly right", and missed that after the *first* sync the cache
holds the authoritative value — so the `??` never falls through again and
a friend's relay freezes at its first value forever. For an account-only
friend that relay is the sole reachability candidate, so they become
permanently unreachable. I reproduced it before accepting the report:

```
after 1st sync : ws://relay-ONE/connect
service says   : ws://relay-TWO/connect
after 2nd sync : ws://relay-ONE/connect
```

The lesson is specific: I reasoned about the *intent* of the expression
and never traced what its inputs contain on the second call. Fixed with
device-level provenance (`relayUrlFromPairing`), the same shape
`Friend.confirmedByAccountService` already uses one level up; unknown
provenance on load counts as not-paired, so existing frozen files
self-correct.

### Cross-round catch
The two rounds ran in parallel against different states, and the app
agent — reading the server's actual code rather than trusting my brief —
found that the new `409 ambiguous_username` was not mapped in
`AccountServiceClient._login`, so it fell through to `502` and the app
rendered "try again in a moment" for a case where retrying can never work
and an operator must intervene. Fixed on both sides.

I then closed the remaining seam myself: the app had been telling a
too-short password from a bad username by *sniffing for the word
"password"* in the message, which the new codes exist to replace. The
client now carries `code`, the UI branches on it, and the old sniff
survives only as the fallback for a node too old to send one. Two of the
four new tests fail if the code branch is removed.

### Verified
`dart format`/`dart analyze` clean; **595 server tests** (from 547) and
**320 app tests** (from 288), all re-run by me. Each server fix was
confirmed load-bearing by defeating it and checking that exactly the
expected tests failed.

**The suite is intermittently flaky.** My first full server run failed;
the next four passed. The implementing agent saw the same thing twice and
could not reproduce it either — an `<html>` body from an ephemeral port
(a port collision with something else on the machine) and one
`account_update_poller` overlap test. Neither is in changed code, but a
suite that fails once in five undermines every "all tests pass" claim we
make, so it is worth chasing before it is treated as noise.

### Open, and Jorge's to decide
- **The relay constant.** Domain + TLS, no default, or the bare IP.
- **Switching accounts on one device drops the previous account's synced
  friends** (no tombstone; they return on switching back, minus
  locally-learned addresses and nicknames). This is ADR 0052's stated
  blast radius becoming reachable for the first time, since before this
  round switching accounts didn't work at all.
- **Casing is not preserved**, so a synced friend displays as `jorge`,
  never `Jorge`.
- **Ambiguous-username recovery is manual** — editing `accounts.json`,
  with no tooling, and the affected users cannot log in meanwhile.
- Outgoing friend requests still have no route, so the app still cannot
  show or cancel one.
