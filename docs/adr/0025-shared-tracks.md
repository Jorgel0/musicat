# 0025 — Shared tracks: the core sharing primitive

## Context
Jorge clarified the actual social feature he wants (2026-08-17, captured
in the plan): never share a raw library or a whole file automatically —
share *metadata* (title, artist, cover) for specific songs/albums a user
chooses to expose, let the recipient decide whether to download, and have
that download go directly between the two Musicat Servers (not through
Soulseek). He described three ways this gets used — a curated "profile"
visible to all friends, a direct send to one specific friend, and joint
playlists — but all three reduce to the same mechanism: expose metadata to
some audience, then serve the real file only to someone actually
authorized for it. This slice builds that one shared mechanism; profile/
direct-send/playlist are just different ways of setting a track's
audience, not decided or built here.

## Decision
- **`SharedTrackVisibility`** — `FriendVisibility(nodeId)` (shared with one
  friend) or `AllFriendsVisibility()` (shared with all of them).
  `.allows(requestingNodeId)` is the object-level authz check every
  sharing route runs *in addition to* [[project_musicat_overview]]'s
  existing "is this even a known friend" check (ADR 0019) — being a
  friend at all is necessary but never sufficient.
  **Generalized the same day — see ADR 0027**: `FriendVisibility` (one
  node) was replaced by `FriendsVisibility` (a set), once a 3+-person
  joint playlist (ADR 0026) revealed a real gap in the original two-case
  design.
- **`SharedTrack`** — `id`, local `filePath` (never sent to a peer
  directly), `title`/`artist`/`album`/`coverArtPath`, `visibility`.
  `toPublicJson()` deliberately omits `filePath`/`coverArtPath` (local
  disk paths — meaningless, and a path-disclosure risk, to a remote peer).
- **App-facing routes** (`/api/v1/library/shared-tracks`, `POST`/`GET`/
  `DELETE`) — how *this* node's own app tells its own server what to
  share. Not yet protected beyond reachability — same known, deliberate
  gap as `/api/v1/federation/friends` (ADR 0019/0020); now a second
  instance of it, which is starting to argue for a general local-API auth
  mechanism rather than a one-off fix per endpoint. Not decided here.
- **Federation-facing routes** (new `/api/v1/sharing/*` prefix — a
  *sibling* of `/api/v1/federation/`, not nested under it: shelf_router's
  `mount()` matches by registration order with no most-specific-first
  resolution, so a genuinely nested route would silently never be reached,
  swallowed by the parent's wildcard first) — `GET /shared-tracks` (what's
  visible to the calling friend), `GET /shared-tracks/<id>/file`, `GET
  /shared-tracks/<id>/cover`. Every one authenticates via a new shared
  `verifiedNodeId(request, verifier)` helper (extracted from `/ping`'s
  inline logic, now used in three places) and then separately checks
  `visibility.allows(nodeId)` before serving anything.

## Consequences
- Unit-tested: `SharedTrackStore` (add/remove/persistence/`visibleTo`
  filtering for both visibility kinds), and the route layer for both
  routers — file-not-found/bad-visibility validation, unsigned/unknown
  callers rejected, and critically, a *real, registered friend* correctly
  getting `403` for a track shared with someone else (not just an
  "unknown node" case, which was already covered by ADR 0019).
- **Verified for real, end to end**: one real running server, two real
  Ed25519 identities registered as its friends through the actual pairing
  flow (ADR 0020), a real 2KB file shared with only one of them. The
  authorized friend listed it (metadata only, no `filePath` leaked),
  downloaded it, and the bytes matched the original file exactly; a
  *different but equally real, trusted* friend got `403`; and a
  never-paired identity got `401`. This is the object-level authz
  requirement from the plan (and this org's standing rule) proven against
  a real request, not just asserted in a unit test.
- Nothing in `app/` calls any of this yet — no share button, no "browse
  what friends shared" screen, no profile/direct-send/playlist UI. This
  slice is purely the server-side primitive those will be built on.
- Joint playlists (grouping multiple `SharedTrack`s with contributions
  from more than one person, plus the "last-write-wins by timestamp" sync
  the plan calls for) are a distinct follow-up — a playlist is really just
  a named, ordered collection of shared-track references, but the sync
  semantics across two independent servers aren't designed yet.
