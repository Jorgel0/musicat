# 0029 — App-side sharing: share a track, browse and download what friends share

## Context
ADR 0025-0027 built the sharing/joint-playlist backend; ADR 0028 gave the
app a Friends section for pairing, but nothing yet let a user actually
send or receive shared metadata from the app. This continues the plan's
Phase 4 "Hecho cuando": a user shares music and the other side downloads
it directly from the sharer's device.

Two real gaps surfaced while wiring this up, both fixed here rather than
deferred:

1. **The app has no signing key.** Every `/api/v1/sharing/*` call is
   friend-signed server-to-server (ADR 0019). Browsing a friend's shares
   from the app therefore can't call the friend's server directly — it
   has to ask *this device's own* server to do it, the same way
   `POST /playlists/<id>/sync` already proxies a signed call on the app's
   behalf. New routes were added to `buildLibraryRouter` (now taking
   `FriendStore`/`NodeIdentity` too): `GET
   /api/v1/library/friends/<nodeId>/shared-tracks` (signs and forwards
   the friend's list) and the matching `.../file` and `.../cover` routes,
   which stream the friend's response straight through via
   `http.Client.send()` rather than buffering. Every proxy route forwards
   the friend's actual status code and body (403/404/etc.) instead of
   flattening failures to a generic 502 — only a genuine network failure
   (unreachable, timeout) gets 502.
2. **`toPublicJson()` didn't expose a file extension.** Nothing else in
   the public shape reveals it, but without knowing `.flac` vs `.mp3` the
   receiving side has no way to name the downloaded file so the existing
   tag-reading import scanner will even look at it (it filters by
   extension). Added `extension` to `SharedTrack.toPublicJson()` — derived
   from the same local `filePath` already used to serve the file, but
   itself not a path and not a privacy leak.

## Decision
- **Share a track** (`app/lib/features/library/presentation/share_with_friend_sheet.dart`):
  a bottom sheet off a new "share" icon on each library track row, listing
  "All friends" plus each real friend from `friendsControllerProvider`,
  calling a new `SharingClient.shareTrack()`
  (`core/network/social/sharing_client.dart` — the reserved placeholder
  package for exactly this, per its own README).
- **Browse and download what a friend shared** (`friends/presentation/friend_detail_screen.dart`):
  tapping a friend in the Friends list (new nested route
  `/friends/:nodeId`) opens their shared-tracks list — title/artist/album,
  a cover thumbnail fetched lazily only when `hasCoverArt` is true, and a
  per-track download button.
- **Download re-uses the existing import pipeline.** Downloading a shared
  track (`friends/presentation/shared_track_download.dart`) writes the
  bytes to `<applicationSupportDirectory>/shared_downloads/<friendNodeId>/<trackId><extension>`
  and then calls the same `LibraryScanner.scanFolder()` the folder picker
  and Soulseek downloads already use — confirmed (Explore agent) to be a
  backend-agnostic primitive with zero Soulseek-specific coupling, exactly
  as intended by the plan's "reutilizar el pipeline de import" note.
- `SharingClient` mirrors `FederationClient`'s shape (ctor, `_handle`,
  exception type) for consistency, but is its own class/file rather than
  new methods on `FederationClient` — sharing and federation are separate
  concerns server-side too (`server/lib/src/sharing/` vs
  `server/lib/src/federation/`).

## Consequences
- **Real, end-to-end verified**, three live `dart run bin/server.dart`
  processes (A/B/C), driven only through the real `SharingClient` +
  `FederationClient` classes via a throwaway script (deleted after use):
  mutual pairing, a direct share (A→B only) and an all-friends share,
  B browsing and downloading A's direct share with byte-for-byte bytes,
  a `null` cover (none set) rather than an error, a real third friend (C)
  correctly getting `403` on the track *not* shared with them but `200`
  on the all-friends one, an unknown-friend proxy call 404ing cleanly,
  and `listMyShares`/`deleteShare` round-tripping on A.
- **Bug caught by that same real run, fixed before commit**: file/cover
  downloads use `ResponseType.bytes`, so a JSON `{"error": ...}` failure
  body arrived as raw undecoded bytes — `SharingClientException` was
  surfacing Dio's generic "status code 403" boilerplate instead of the
  server's actual "Not shared with you". Fixed by decoding
  `List<int>` response data as UTF-8 JSON before falling back to the
  generic message; re-verified the real message comes through correctly.
- The download-and-import step itself (`shared_track_download.dart`) is
  Flutter/`path_provider`/Drift-specific and wasn't exercised by the
  throwaway script — only the HTTP layer underneath it was. Not yet
  manually tested against a real running app.
- `dart analyze`/`dart test` clean on both `server/` (127 tests, +7 new
  for the friend-proxy routes) and `app/` (120 tests, unchanged — no new
  unit tests were added for `SharingClient` itself, matching the existing
  precedent that `FederationClient` also has none, relying on real
  end-to-end verification instead).
- Still open: no UI for a "profile" (curated always-visible selection)
  distinct from the plain share sheet, no UI yet for joint playlists
  (ADR 0026), and downloaded shared tracks are always tagged
  `TrackSource.local` by the scanner today — the same pre-existing gap
  already noted for Soulseek downloads (`TrackSource.soulseek` is dead
  code), not something newly introduced here.
