# 0051 — Friend requests end to end, and a friend you can actually reach (Fase 5, item 3 round B)

## Context
ADR 0050 built the bridge from the account service to local trust, and
named the gap it left: `DeviceLink` recorded no reachability at all, so
two people who became friends purely through the account service could
each *verify* the other's signed requests but neither could *initiate*.
"Add a friend by username" produced a friend you couldn't use — exactly
the experience Fase 5 exists to remove.

This round closes that, and adds the delivery half item 3 was always
about: push over the relay tunnel, with polling as the guaranteed
fallback.

## Decision
- **The account service records each device's relay URL.** `DeviceLink`
  gains a nullable `relayUrl`, sent by the node at
  `POST /accounts/login/complete` (it already knows its own configured
  relay), returned by `GET /<id>/devices` and `GET /<me>/friends`. A
  synced friend then has a relay candidate and `reachFriend` routes
  `<relay>/<nodeId>/<path>` — the ADR 0033 mechanism already proven
  across real networks in ADR 0035 and 0047. This discloses which relay
  you use to your mutual friends; that is not new (`relayUrl` is already
  exchanged at pairing today) but it is now a stated choice.
- **`mergeFriendDevices` prefers the locally-learned relay and falls back
  to the authoritative one**, leaving `address`/`udpCandidate` local-only.
  Its doc comment previously asserted, as fact, that the account service
  records no reachability whatsoever — that is now false for `relayUrl`
  alone, and the comment is corrected. A stale comment there would have
  misled the next person badly.
- **The push carries no data.** The new hub→node message is exactly
  `{"type":"notify","event":"friendRequests"}` and nothing else; the node
  responds by doing the same authenticated re-fetch its own poll would
  have done later. A compromised or malicious relay can therefore cause
  extra polling and nothing else — it can never inject a friend or a
  request. `event` is deliberately an opaque `String` rather than a
  decoded enum, because on both sides of this protocol a `FormatException`
  tears the whole tunnel down, so an unrecognized kind from a newer hub
  must be ignorable.
- **Polling at 5 minutes** as the correctness fallback, on top of round
  A's 30s `minSyncInterval` floor — two different numbers: one rate-limits
  bursts from below, the other bounds staleness from above. 288 ticks/day
  of two small signed GETs, and **exactly zero for a node with no
  session**, which keeps faith with the mobile-data constraint from ADR
  0036.
- **Node app routes** `GET/POST /api/v1/account/friend-requests` and
  `.../accept|decline`, all `requireLocal`. Accept awaits a forced sync,
  so the new friend is already in `GET /api/v1/federation/friends` when
  the call returns — matching what round A's login does.

## Consequences
- **The payoff is real, and I verified it myself rather than accepting the
  agent's report.** I wrote and ran my own end-to-end: a real relay (wired
  exactly as `bin/relay.dart` does, hub + account router in one process)
  and two real `startMusicatServer` nodes, made friends **purely by
  username** — no pairing code, no address, nothing typed. Alice's poll
  interval was set to **12 hours**, so only the push could possibly have
  told her; her friend list converged within 2 seconds of Bob's accept.
  The resulting friend has `address: null`, `udpCandidate: null` and only
  a `relayUrl`. Bob shared a 64 KiB file and Alice listed and downloaded
  it: `200`, 65536 bytes, sha256 identical to the source. With no address
  anywhere, the relay was the only possible route.
- Gates: `dart format`, `dart analyze` clean, **489 server tests** (up
  from 435), 231 app tests. `Friend.toJson()` is untouched, so the app's
  parser is unaffected.
- I confirmed the two properties I care most about by reading the code,
  not just the tests: `mergeFriendDevices` really does prefer local and
  fall back to authoritative, and the runtime's `onNotify` really does
  discard everything but the event name before triggering a re-fetch —
  there is no path from a push into `FriendStore`.

### What this still doesn't do
- **Account-service-side unfriending does not propagate.** The sync stays
  additive-only (ADR 0050's stated limitation, deliberately unchanged).
- **A device's relay is only refreshed at login**, so a friend who changes
  relays needs a re-login; until then the stale relay 502s and the chain
  falls through.
- **No pushes are queued.** A disconnected node finds out on its next
  poll; storing nudges would give the hub durable per-node state it
  deliberately has none of.
- A pre-round-B node connecting to a post-round-B relay drops and
  re-establishes its tunnel each time it is pushed to, because
  `RelayMessage.decode` throws on an unknown type. Harmless here (we
  control both ends and they ship together), but it is the reason the new
  message keeps `event` untyped, and it would need fixing before any
  genuinely mixed-version deployment.

## Where Fase 5 stands
Items 1-3 are done: accounts, account-based trust, and friend requests
working end to end over a real relay. **Item 4 (the app UI) is now the
only thing between this and Jorge actually using it** — everything it
needs exists as a local, loopback-only HTTP contract. Item 5 (desktop
slskd auto-launch) and 5-bis (mDNS for the same-LAN, relay-down case) stay
independent.
