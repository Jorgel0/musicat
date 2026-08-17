# 0030 — App-side joint playlists, and a real routing bug ADR 0026 missed

## Context
ADR 0026 built joint playlists server-side; nothing in the app called any
of it yet. Jorge chose (2026-08-17, asked directly since it's exactly the
kind of navigation-placement call he'd corrected before in ADR 0028) to
surface joint playlists as a **second tab inside the existing Playlists
screen** — "Mine" (the pre-existing local, Drift-backed playlists) and
"Joint" — rather than under Friends or as a new top-level destination.

While building the app-side client and running it against two real
servers, `POST /api/v1/playlists` 404'd with shelf_router's own generic
"Route not found" body — a genuine, previously-unnoticed bug, live since
ADR 0026, that no unit test had ever caught.

**Root cause**: `playlist_routes.dart`'s routes were registered as
`/playlists`, `/playlists/<id>`, etc. — but the router is *mounted* at
`/api/v1/playlists/` in `bin/server.dart`. That doubles the segment: the
actual reachable path was `/api/v1/playlists/playlists`, not
`/api/v1/playlists`. Every other router in this codebase avoids this
because its routes use a segment name distinct from its own mount prefix
(`/api/v1/library/shared-tracks`, `/api/v1/sharing/shared-tracks`) —
`buildPlaylistRouter` is the only one whose routes literally repeat its
own mount prefix's last segment. `playlist_routes_test.dart`'s unit tests
never caught this because they call `buildPlaylistRouter(...).call`
directly, bypassing `mount()` (and its prefix-stripping) entirely — they
were exercising the router's own registered paths, which is correct
*for* those paths, but never tests that the paths make sense once
mounted. ADR 0026's "verified for real, two live servers" note appears
to have been written without anyone (agent or Jorge) trying the actual
mounted address — this went unnoticed until this session's app-side
`JointPlaylistClient` hit the real server as a genuinely independent,
address-guessing-from-the-route-file caller would.

**Second, smaller wrinkle found while fixing the first**: after
correcting the routes to `/`, `/<id>`, etc., the *bare* collection route
(`POST`/`GET` with nothing after the mount prefix) still 404'd —
`shelf_router`'s `mount(prefix, handler)` behaves differently depending
on whether `prefix` itself ends in `/`: with a trailing slash, it only
ever registers a wildcard requiring *something* after that slash, so a
request to the bare `/api/v1/playlists` (no trailing slash) never
matches at all and 404s at the *outer* router. Every other mount in
`bin/server.dart` keeps its trailing slash because none of those routers
have a genuine bare-`/` route — `buildPlaylistRouter` is the only one
that does. Fixed by mounting it as `/api/v1/playlists` (no trailing
slash) instead — confirmed via `shelf_router`'s own source that this
form registers *both* the bare-prefix route and the `<path>`-suffixed
one, so both `/api/v1/playlists` and `/api/v1/playlists/<id>` resolve
correctly.

## Decision
- Server: `playlist_routes.dart`'s routes changed from `/playlists`,
  `/playlists/<id>`, `/playlists/<id>/items`, `/playlists/<id>/sync` to
  `/`, `/<id>`, `/<id>/items`, `/<id>/sync`; `bin/server.dart` mounts it
  at `/api/v1/playlists` (no trailing slash, unlike every sibling mount).
  `playlist_routes_test.dart` updated to match — its tests call the
  router directly either way, but now with paths that actually reflect
  what a real mounted request looks like.
- Also added `extension` to `PlaylistItem` (mirroring the same field
  already added to `SharedTrack.toPublicJson()` in ADR 0029) — a
  participant downloading someone else's playlist item needs it to name
  the file, and `extensionOf()` (promoted from a private helper in
  `shared_track.dart` to a shared top-level function) is now reused by
  both.
- App: `JointPlaylistClient` (`core/network/social/`), a
  `jointPlaylistClientProvider` alongside the existing federation/sharing
  ones, and `myNodeIdProvider` (so a playlist item this device added
  itself is shown differently from one to download).
- `PlaylistsScreen` restructured into a `TabController`-driven shell over
  two extracted tabs (`LocalPlaylistsTab`, unchanged behavior;
  `JointPlaylistsTab`, new) with a per-tab FAB. `JointPlaylistDetailScreen`
  (new top-level route `/joint-playlists/:id`, sibling to `/playlists/:id`
  rather than nested under it, since the ids are different types and
  address different data sources entirely) shows items with a download
  button (or a "you added this" indicator), a manual sync action, and a
  dialog to copy the playlist's own id — there's no invite-link mechanism
  (still not designed, per ADR 0026), so sharing the id out of band is
  the only way to join one today.
- `downloadAndImportSharedTrack` (added in ADR 0029 for a friend's direct
  shares) generalized to take raw `(ownerNodeId, trackId, extension)`
  instead of a `SharedTrackSummary`, so both a friend's shared-tracks list
  and a joint-playlist item can reuse the exact same download+import path.

## Consequences
- **Real, end-to-end verified**, two live `dart run bin/server.dart`
  processes, driven only through the real `JointPlaylistClient` +
  `FederationClient` + `SharingClient` classes via a throwaway script
  (deleted after use) — against the *actual* mounted server, not the
  router in isolation: mutual pairing, A creates a playlist and adds a
  track, B joins the same id and syncs (no errors, correct extension),
  B downloads A's item byte-for-byte, B adds its own track, A re-syncs
  and sees both (proving the union merge still works end to end through
  the now-fixed routing), and a deleted playlist correctly 404s
  afterward. This same run is what caught both routing bugs above.
- This is the second time in this project a routing bug survived
  passing unit tests because the tests called a router's handler
  directly instead of through its real mount — worth remembering next
  time a new router is added: a unit test proves the routes work *as
  registered*, not that they're *reachable at the address the rest of
  the app assumes*.
- `dart analyze`/`dart test` clean on `server/` (127 tests, route paths
  updated, no count change) and `app/` (120 tests, no new ones — same
  precedent as ADR 0028/0029 of relying on real end-to-end verification
  for these Dio-based clients rather than unit tests).
- Still open: no invite-link/QR mechanism for sharing a joint playlist's
  id (manual copy-paste only); no visual indicator in the list for
  "someone added something since you last synced" (sync is always
  manual); the "profile" sharing concept (ADR 0025's third mechanism)
  still has no UI.
