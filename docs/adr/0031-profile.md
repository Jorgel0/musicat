# 0031 — "My Profile": curated songs/albums visible to all friends

## Context
The plan's third Phase 4 sharing idea (Jorge, 2026-08-17 note) was a
personalizable profile: curate songs and albums from the local library
that stay visible and downloadable by *every* friend. The underlying
mechanism — `AllFriendsVisibility` — already existed (ADR 0025) and was
already reachable one track at a time via the "All friends" option in
`share_with_friend_sheet.dart`. What was missing was a dedicated place
to *see and manage* that whole curated set at once, and a way to add or
remove an entire album in one action rather than track by track.

Checking the server API before writing anything: `GET
/api/v1/library/shared-tracks` (`buildLibraryRouter`) already returns
every one of this node's own shares via `toStorageJson()`, which
includes `visibility` — so no server change was needed here, unlike
ADR 0029/0030. The app-side `MySharedTrack` model just wasn't parsing
that field (or `filePath`, needed to tell whether a given local `Track`
is already shared).

## Decision
- `MySharedTrack` (`core/network/social/sharing_client.dart`) gained
  `filePath` and `isAllFriends` (derived from `visibility.type ==
  'allFriends'`) — both already present in the server's response, just
  unparsed before.
- `myProfileTracksProvider` (`friends/presentation/my_profile_providers.dart`):
  `listMyShares()` filtered to `isAllFriends` only — a direct send to a
  specific friend is not part of the profile.
- `MyProfileScreen`, reached via a new "My profile" icon in the Friends
  app bar (only shown once a Musicat Server is configured) and route
  `/my-profile`: two tabs, "Songs" (every library track with a checkbox
  reflecting current profile membership) and "Albums" (every album with
  a tristate checkbox — unchecked/checked/dash for none/all/some of its
  tracks shared). Toggling a song calls `addTrackToProfile`/
  `removeTrackFromProfile`; toggling an album calls
  `addAlbumToProfile`/`removeAlbumFromProfile`, which loop over the
  album's tracks (matched by the same case-insensitive album+artist key
  `library_grouping.dart` already uses) and add/remove each one that
  isn't already in the requested state — no new bulk server endpoint,
  since N sequential calls for an album's worth of tracks is simple and
  the size involved is small.
- The album checkbox's tristate *display* (none/all/partial) is
  intentionally decoupled from Flutter's own tristate tap-cycle
  (false→true→null→false): the actual tap handler always computes
  "is it currently fully shared?" itself and either adds the gap or
  removes everything, rather than trusting whatever value Flutter's
  cycle would hand back — the built-in cycle order doesn't match the
  desired "top up or clear" interaction.

## Consequences
- **Real-verified**, one live `dart run bin/server.dart` process, driven
  through the real `SharingClient` class via a throwaway script (deleted
  after use): two tracks shared as `allFriends` and one sent directly to
  a (fake) specific friend, confirming `listMyShares()` round-trips
  `filePath`/`isAllFriends` correctly and that filtering to
  `isAllFriends` — the exact logic `myProfileTracksProvider` uses —
  correctly separates the two "album" tracks from the direct one; then
  removing both by id and confirming only the direct share remains.
- Not covered by that script, same caveat as ADR 0029/0030: the actual
  Flutter widgets (checkbox taps, tristate display, provider
  invalidation re-rendering the list) weren't exercised against a real
  running app — only the HTTP/parsing layer underneath them.
- No server changes were needed for this slice at all — the entire
  gap was app-side (an unparsed field and a missing management screen),
  a good sign the sharing primitive from ADR 0025 was already general
  enough to cover a use case it wasn't originally built with a UI for.
- `dart analyze`/`dart test` clean; app test count unchanged at 120 (no
  new unit tests, same established precedent as the other Dio-based
  clients in this project — relying on real end-to-end verification
  instead).
- Still open in Fase 4: the receiving side never distinguishes "this was
  in so-and-so's profile" from "sent to me directly" — by design, since
  `toPublicJson()` deliberately omits visibility (ADR 0025) and, more to
  the point, a friend doesn't need to know which mechanism put a track
  in front of them, only that it's theirs to download. NAT traversal
  across a real network boundary remains unverified.
