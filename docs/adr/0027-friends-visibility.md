# 0027 — Generalize sharing visibility to a set of friends

## Context
Jorge pointed out (2026-08-17) that a joint playlist (ADR 0026) needs to
support more than two people. Checking the actual code against that
turned up a real gap: `PlaylistItem` creation had to pick a
`SharedTrackVisibility` for the new `SharedTrack`, and `FriendVisibility`
(ADR 0025) could only name *one* node. With more than one other
participant, the code fell back to `AllFriendsVisibility` — which would
have shared the track with **every friend of the adder's**, not just the
other people actually in that playlist. A 3-person "Group trip" playlist
would have leaked its tracks to every other friend the adder has, a
direct violation of the object-level authz this whole feature is built
around.

## Decision
- **`FriendVisibility(String nodeId)` → `FriendsVisibility(Set<String>
  nodeIds)`.** A direct send to one friend is just the one-element case;
  `SharedTrackVisibility.friend(nodeId)` still exists as a convenience
  factory returning `FriendsVisibility({nodeId})`.
- Playlist item creation now always uses
  `FriendsVisibility(playlist.participantNodeIds.toSet())` regardless of
  how many other participants there are — no more branching on
  `participantNodeIds.length`, and no path that ever falls back to
  `AllFriendsVisibility` for a playlist.
- `fromJson` still accepts the old single-`nodeId` `'friend'` wire shape
  (mapping it to a one-element `FriendsVisibility`) alongside the new
  `'friends'`/`nodeIds` shape — there's no persisted production data to
  migrate, but the parser costs nothing extra to keep both understood.

## Consequences
- Added a regression test that creates a 3-person playlist (two other
  participants) and asserts the resulting `SharedTrack`'s visibility
  allows both actual participants but rejects a fourth, real, trusted
  friend who isn't in that playlist — the exact scenario that was broken.
- The HTTP-layer enforcement of `visibility.allows()` itself (401/403 for
  the wrong caller) was already verified for real, end to end, in ADR
  0025 — this fix is about the *data* constructed before that
  already-proven check runs, so it's covered by the new unit test rather
  than repeating a full multi-server real-network verification for what's
  the same enforcement code path underneath.
- No change needed to `AllFriendsVisibility`, `FriendStore`, or any route
  handler beyond the one line in `playlist_routes.dart` that was
  constructing the wrong visibility — the polymorphic `allows()` design
  meant every authz check elsewhere kept working unmodified.
