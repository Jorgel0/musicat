# 0041 — Fix crossed friend names; add a purely local nickname

## Context
The real two-device test in ADR 0040 surfaced a genuine UX/design bug:
`_AddFriendSheet`'s "Name (optional)" field was filled in by the person
*adding* a friend, apparently to label that friend — but
`FederationClient.addFriend()` actually sends whatever's typed there as
the caller's own `displayName` in the `POST /friends` body. So when both
sides of a pairing typed a name expecting to label the other, each side's
self-description ended up describing the *other* person, and names came
out crossed. First slice of Fase 4.6 (see the plan file), which Jorge
scoped in full after that test: this fix, then an embedded server (no
Termux), then a username directory (no manual IPs) — each its own
`/dev-team` round and ADR, per the plan's stated delivery order.

## Decision
Two names, kept structurally separate, never able to cross again:
- **`displayName`** — what a friend calls *themselves*, self-reported,
  arrives automatically via their own `addFriend` call. Nothing new here
  except that it's now actually populated correctly, because of the
  second change below.
- **`localNickname`** (new) — what *this device's own user* chooses to
  call a friend, purely local, never transmitted anywhere.

**Server** (`server/lib/src/federation/`):
- `Friend` gains `localNickname` (nullable, persisted in `friends.json`,
  same pattern as `relayUrl`). Confirmed by grep that no code path
  building an outgoing federation request ever touches it —
  `friend_reachability.dart` only uses `address`/`relayUrl`/`nodeId` to
  build a URI, never a payload.
- New `PATCH /friends/<nodeId>` (app-facing only, same
  no-`RequestVerifier` pattern as the existing `GET`/`DELETE
  /friends/<nodeId>` — see Consequences for a related gap this surfaced):
  sets or clears `localNickname`, 404 for an unknown friend.
- `GET /friends` already returns full `Friend` JSON, so `localNickname`
  is included automatically.

**App**:
- `MusicatServerConfig` gains `myDisplayName`, set once in the server
  config sheet, persisted like `host`/`port`/`myPublicAddress`.
- `FriendsController.addFriend()` no longer takes a `displayName`
  argument from its caller — it always sends `config.myDisplayName`.
  `_AddFriendSheet`'s "Add a friend" section drops the "Name (optional)"
  field entirely; there's nothing left to type there.
- `FederationFriend.displayLabel` (`localNickname ?? displayName ??
  nodeId`) is the one shared precedence rule both the friends list and
  `FriendDetailScreen` use, so they can't drift apart on which name wins.
- `FriendDetailScreen` gains an "Edit nickname" action (a small dialog)
  calling the new `PATCH` endpoint via `FriendsController.setLocalNickname`.

## Consequences
- `dart analyze`/`dart test` (server, 162 passed) and `flutter analyze`/
  `flutter test` (app, 177 passed) both clean — verified directly, not
  just from the implementing subagents' reports.
- **A real, pre-existing security gap surfaced while reviewing this
  slice, not caused by it**: `bin/server.dart` binds to `0.0.0.0`, and
  only federation-facing (peer-to-peer) routes go through
  `RequestVerifier`. Every app-facing route — friend management
  (including this ADR's new `PATCH`), library/playlist management,
  pairing-code generation — has no authentication at all; reachability
  alone (LAN, a direct public IP, or through the relay just by knowing a
  `nodeId`) is enough to call them. This predates this ADR, but Fase
  4.6's next piece (a username directory, explicitly designed to make
  finding someone's address *easy*) would make this gap meaningfully
  worse. Needs a real fix — most likely restricting app-facing routes to
  loopback-only connections — before the directory ships. Not fixed
  here; tracked to be addressed before Fase 4.6 item 3.
- The self-invite QR/link still doesn't carry `myDisplayName` — not
  needed, since the field it used to fill (in the redeeming side's
  now-removed "Name (optional)") no longer exists, and the inviter's
  real name arrives automatically once the code is redeemed anyway.
- Next in Fase 4.6: the embedded server (no Termux), then the username
  directory (no manual IPs) — see the plan file for the full approved
  design of both.
