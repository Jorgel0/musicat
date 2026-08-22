# 0034 — Wire the relay as an automatic fallback in production call sites

## Context
ADR 0033 built and verified the relay mechanism itself (`RelayHub`/
`RelayClient`), but left it disconnected from the actual feature call
sites on purpose: every friend-to-friend HTTP call (pairing, browsing/
downloading shares, playlist sync) still addressed a friend only at
their stored direct `Friend.address`. This closes that gap: the same
calls now try direct reachability first and fall back to the friend's
relay automatically when direct fails, with no manual "address via
relay" workaround needed by a caller.

## Decision
- **`Friend` gains `relayUrl`** (nullable, symmetric to the existing
  `udpCandidate`), persisted in `friends.json` like every other field.
- **Pairing (`POST /friends`) exchanges it automatically**: the caller's
  own relay (if actually connected — `bin/server.dart` now tracks
  connection success, not just configuration, and only advertises a
  `relayUrl` that's genuinely live) is sent as part of the pairing
  payload and stored by the receiver; the receiver's own relay is
  returned in the response, mirroring the existing `udpCandidate`
  exchange. `GET /api/v1/node` also now reports this node's own
  `relayUrl`, so the app can read it when redeeming a friend's code.
- **`reachFriend`/`reachFriendStreamed`** (new
  `server/lib/src/federation/friend_reachability.dart`): try
  `Friend.address` directly with a 5s timeout; on any network-level
  failure (timeout, connection refused, DNS failure), and only if the
  friend reported a `relayUrl`, retry via
  `<relay's http(s) origin>/<nodeId>/<path>`. An application-level error
  response (4xx/5xx) from a friend reached directly is returned as-is —
  that's a real answer, not a reachability problem, so it never
  triggers a relay retry.
- **All three friend-to-friend call sites now go through it**:
  `sharing_routes.dart`'s two proxy routes (the shared-tracks list, and
  the streamed file/cover download) and `playlist_routes.dart`'s sync.
  Each needed only its one `client.get(...)`/`client.send(...)` call
  swapped for `reachFriend(...)`/`reachFriendStreamed(...)` — no other
  changes, since the helper takes the same `Friend` and returns the same
  response types.
- **`bin/server.dart`'s startup order changed** to make this possible:
  the relay connection is now attempted *before* the federation router
  is built (since a successful connection is what gets advertised at
  pairing time), while `RelayClient` still needs the final request
  handler to service tunneled requests — resolved with a forwarding
  closure over a `Handler?` variable assigned once the real handler is
  built moments later. By the time any real tunneled request could
  possibly arrive, the assignment has already happened.

## Consequences
- **Real, end-to-end verified** with three live processes (a relay, two
  Musicat Servers), through the actual production code paths this time —
  not a manually relay-addressed script like ADR 0033's:
  1. Paired A and B via their ordinary *direct* addresses (the normal
     flow) and confirmed `relayUrl` was exchanged automatically on both
     sides with zero manual relay-addressing.
  2. A shared a track with B; B fetched it successfully while direct
     reachability still worked (sanity check).
  3. **Corrupted B's stored direct address for A** (edited `friends.json`
     to an unreachable port, restarted B) while leaving A's relayUrl
     intact — simulating "this friend's address stopped working, but
     their relay is still valid" (e.g. they changed networks).
  4. Called the *exact same* production endpoint
     (`GET /api/v1/library/friends/<nodeId>/shared-tracks` on B) —
     succeeded, having fallen back to the relay automatically.
  5. Did the same for the streamed file-download proxy — byte-for-byte
     correct.
  6. Did the same for joint-playlist sync (a separate file,
     `playlist_routes.dart`) with A's address still broken on B's side —
     synced with `"errors":[]`, correctly merging in A's item.
- `dart analyze`/`dart test` clean; server test count 139 → 148 (7 new
  `friend_reachability` tests covering direct success, an application
  error not triggering a fallback, a genuine network failure falling
  back correctly, rethrowing when there's no relay to fall back to, and
  the streamed variant; 2 new `friend_store` tests for `relayUrl`
  round-tripping). App: 120 tests unchanged, `flutter analyze` clean.
- Still open: no reconnect/retry if a relay connection drops after
  startup (same gap ADR 0033 already flagged); no UI surface showing
  whether a friend has a relay on file or whether a given request
  actually used one (works silently, which is the point, but also means
  there's no visibility into it from the app); real deployment and a
  second real cross-NAT test with an actually-hosted relay is still
  Jorge's call, not done here.
