# 0049 — Accounts as the unit of federation trust (Fase 5, item 2)

## Context
ADR 0048 built the account service but nothing consumed it:
`FriendStore`/`RequestVerifier` still resolved trust exactly as they had
since Fase 4 — one friend, one pinned `nodeId`, one key. This round makes
an *account* the unit of trust, so a friend can have several devices and
can link a new one without re-pairing with everybody.

The design's load-bearing idea (see the plan's "Fase 5" section) is that
**an account is the general case and today's device-pinned friend is the
degenerate one-device case**: a legacy friend's `accountId` is its own
`nodeId`, so no `friends.json` on disk needs rewriting. That property held
up — it is verified by real legacy-format fixtures in
`friend_store_test.dart`, not just asserted.

Two hard rules constrain everything here, both from Jorge directly:
1. **Offline.** Two established friends must be able to share music with
   the relay *and* the account service unreachable ("estoy con un amigo y
   el relay está caído, pero estamos en la misma red").
2. **Unfriending sticks.** Removal is instant, local, and no later
   refresh or sync may resurrect it.

## Decision
- **`Friend` gains `accountId` + a cached `List<FriendDevice>`.** Its
  `toJson()` stays a *superset* of the old shape (`nodeId`,
  `publicKeyBase64`, `address`, … projected from the primary device, with
  non-null fallbacks) so the app's existing parser is untouched and a
  rolled-back build can still read a file this version wrote.
- **The offline rule is enforced structurally, not by convention.**
  `FriendStore` and `request_signing.dart` import nothing networked.
  `RequestVerifier` is handed an `UnknownDeviceResolver` — a one-method
  interface — never an HTTP client, and consults it *only* on a cache
  miss. Passing `null` (what `UdpPuncher` does, so an unsolicited UDP
  packet can never trigger account-service traffic) makes a network call
  impossible by construction.
- **Local removal is recorded as a tombstone** (`removed_friends.json`),
  checked by every path that could re-learn an account. A tombstone also
  records the removed account's **device nodeIds**, so a request from a
  known-removed device is refused from local disk alone rather than
  costing an account-service lookup to discover whose it is.
- **Revocation of a *device* remains bounded-delay** (30-minute refresh),
  deliberately, per the 2026-09-04 decision: push invalidation is not
  built. Revocation of a *friendship* stays instant and local.

## Consequences — the review round is the substance here
Five adversarial lenses ran against the finished refactor, and reported
16 findings. I re-verified each serious one against the source and `git
show HEAD:` before accepting it. Five were real defects worth this ADR:

- **A dead relay could stall a same-LAN download for minutes.**
  Generalizing reachability to several devices emitted one *untimed*
  relay candidate per device, interleaved *ahead* of the next device's
  direct address. Before this refactor there was exactly one relay
  attempt and it was terminal. Measured: 133.9s with one stale cached
  relay, 267.8s with two — squarely against rule 1, in the exact scenario
  that motivated it. Now all direct addresses are tried before any relay,
  and relay attempts are bounded by their own (more generous)
  `relayTimeout`.
- **`FriendStore` was the only store in the codebase without a mutex.** A
  `remove()` landing inside `updateDevices()`'s load-mutate-save window
  was silently undone — the friend reappeared *with their keys*, so their
  signatures verified again, permanently. Reproduced at 9% (11/120) with
  the real refresher. This is the same race already fixed twice here
  (issue #8); it now uses the same `Future`-chaining lock as
  `AccountStore` and `UsernameDirectoryStore`.
- **The migration path created two friends for one person.** `add()`
  deduped only on `accountId`, so a legacy friend who re-pairs claiming
  their new account ended up with both entries — and `DELETE` removed
  only one, leaving that device fully trusted. `add()` now supersedes any
  entry sharing a device nodeId. (`updateDevices` deliberately does not:
  it is fed by the account service, whereas `add()` *is* the user's
  explicit local decision.)
- **`POST /friends` never checked that a nodeId was the fingerprint of
  the key sent with it.** This gap predates the refactor, but the account
  claim escalated it from "a mislabelled key" to full account
  impersonation: pair with the victim's nodeId, the victim's accountId
  and your own key, and the account service confirms the pair honestly.
  `nodeIdForPublicKey` is now one shared definition in
  `node_identity.dart`, used by all three places that accept such a pair
  (`relay_hub`, `account_routes`, `federation_routes`) instead of three
  copies of the same three lines.
- **The account service sat ahead of the timestamp check.** A request
  with a garbage signature and a made-up nodeId cost 5s, unauthenticated,
  and drained the shared 10/min lookup budget. The clock-skew check moved
  above the resolver. (An unknown nodeId with a stale timestamp now
  reports `staleTimestamp` rather than `unknownNode`; both were and remain
  rejections, and no route's HTTP status changes.)

Also fixed, lower severity: a deterministic precedence rule for
`findByDeviceNodeId` (device-pinned wins) instead of file insertion order,
which had been observed to flip authorization outcomes; a guard against a
confirmed `accountId` colliding with an existing device-pinned friend; an
id check on `POST /playlists/<id>/sync`, which merged whatever playlist a
friend answered with (pre-existing, confirmed by re-testing at HEAD); and
`FriendDeviceRefresher` abandoning a sweep after the first unreachability
rather than paying the 5s timeout once per friend, forever.

**The most valuable finding was about a test, not the code.**
`offline_sharing_test.dart` guarded rule 1 by pointing the account service
at a *closed port*, which refuses in ~14ms — indistinguishable from never
being called. It would have stayed green if the account service were
consulted on every single request. It now points at a **recording
blackhole** and asserts **zero requests were received**, with the stranger
test asserting the opposite so the check cannot go quietly vacuous. That
test is what caught the tombstoned-device gap: unfriending a peer whose
devices kept calling cost a 5s lookup each time (now 1.2ms, no call).

Gates: `dart format`, `dart analyze` clean, **378 server tests** (from
370) and 231 app tests pass. Verified beyond the suite: real pairing
between two `startMusicatServer` instances still returns 201, an
impersonation attempt returns 400, a rejected attempt does not burn the
single-use pairing code, and no duplicate friend is created. The two
highest-value regression tests were confirmed load-bearing by defeating
their fix and watching them fail.

Still open, deliberately: `POST /playlists/<id>/sync` can still *widen* a
playlist's participant set from a friend's response (pre-existing, ADR
0027's class of leak, not narrowed here); the resolver's global lookup
budget is still reachable by unauthenticated strangers with distinct
nodeIds; and nothing yet consumes friend *requests* — that is item 3.
