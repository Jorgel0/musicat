# 0026 — Joint playlists: union-merge sync on top of shared tracks

## Context
The plan's Fase 4 "Hecho cuando" is specifically a joint playlist syncing
between two nodes. Jorge's clarified model (ADR 0025): each participant
adds their *own* local tracks, and the track gets offered to the others
for direct peer-to-peer download — a joint playlist is really just a
named, ordered collection of [[project_musicat_overview]]'s shared-track
mechanism, with sync layered on top. The plan calls for "sincronización
simple (last-write-wins por timestamp)".

## Decision
- **`PlaylistItem`** — `title`/`artist`/`album` (self-contained, so
  browsing a playlist never needs a live round-trip to the item's owner),
  `ownerNodeId` + `sharedTrackId` (where to actually download it from —
  reuses ADR 0025's endpoints directly, no parallel download mechanism).
- **`JointPlaylist`** — `id`, `name`, `participantNodeIds` (the *other*
  participants), `items`, `updatedAt`. Each participant keeps their own
  local copy; there's no central server holding one true version.
- **Sync is a per-item union, not whole-object last-write-wins**, despite
  the plan's literal wording. The only mutation participants actually do
  to *each other's* contributions is adding — nobody edits someone else's
  item — so a union by `PlaylistItem.id` can never lose a concurrent
  addition from either side the way replacing the whole object on an
  `updatedAt` comparison would. `updatedAt` itself still resolves as
  last-write-wins (`max` of both sides), so "most recently touched by
  anyone" is preserved for whatever future use wants it. This is a
  conscious refinement of the plan's original wording, made explicit here
  rather than silently substituted.
- **Joining an existing playlist**: `POST /api/v1/library/playlists` now
  accepts an optional `id` — supplying one already created by someone else
  *joins* that playlist rather than minting a disconnected new one.
  Without this there'd be no way for two nodes to ever agree on which
  playlist they're both talking about. How that id is actually
  communicated between two people (an invite link, a code shown in the
  app, ...) isn't designed — this only makes the id itself reusable.
- **`POST /api/v1/library/playlists/<id>/sync`** (app-facing) pulls each
  participant's current view via a signed `GET
  /api/v1/sharing/playlists/<id>` (federation-facing, object-level authz:
  caller must be in `participantNodeIds`) and merges it in. Manual/on-demand
  only in this slice — no background polling.
- `/api/v1/sharing/playlists/<id>` lives in the *same* `Router` instance
  as `/api/v1/sharing/shared-tracks/*` (ADR 0025), not a separately-mounted
  one at an overlapping prefix — the same `mount()`-ordering hazard noted
  there applies to any two routers sharing a prefix, not just
  `/federation/` vs `/sharing/`.

## Consequences
- Unit-tested: `JointPlaylistStore` (persistence, and specifically that
  `mergeRemote` unions rather than replaces — a concurrent local-only and
  remote-only item both survive, a duplicate item across both sides is
  deduplicated, `updatedAt` picks the later of the two) and the route
  layer (create, join-by-id, add-item wiring a real `SharedTrack`, and
  sync via a mocked HTTP client asserting the exact path called).
- **Verified for real, end to end, across two real running servers**: A
  created a playlist and added its own real file; B joined the same
  playlist id and synced, pulling A's item with no errors; B downloaded
  the actual file through the playlist's owner/sharedTrackId reference,
  confirmed byte-for-byte against the original; B then added its *own*
  real file to its local copy; A synced and its view showed **both**
  items — proving the union merge actually preserves concurrent
  contributions from both sides, not just a scripted unit-test claim.
- Nothing in `app/` calls any of this yet (same as ADR 0025) — no
  playlist UI, no invite flow for sharing a playlist id with a friend.
- No background/automatic sync — a participant only sees a friend's
  addition after explicitly calling `/sync`. Worth revisiting once there's
  an app to drive when that should happen (on open, periodically, a push
  notification, ...) — not decided here.
- Removing an item, or a participant leaving, isn't handled — the model
  today is add-only, matching exactly what was asked for and no more.
