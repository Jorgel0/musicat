# 0044 — Restrict app-facing routes to loopback callers, with an API-key escape hatch for genuine remote self-hosting

## Context
Found while reviewing ADR 0041's `PATCH /friends/<nodeId>` addition, but
predating it: `musicat_server_runtime.dart` binds to every interface, and
only genuinely federation-facing routes (pairing-code *redemption*, and
everything under `/api/v1/sharing/`) go through `RequestVerifier`. Every
*app-facing* route — meant only for "this device's own app talking to its
own local server" — had no authentication at all. Reachability alone
(LAN, a direct public IP, or through the relay just by knowing a
`nodeId`) was enough to: mint a fresh pairing code via `POST
/api/v1/federation/pairing-codes` and immediately redeem it as your own
identity via `POST /api/v1/federation/friends`, self-granting trust with
zero involvement from the device's real owner; list/remove its real
friends; manage its shared tracks and joint playlists; control its
Soulseek backend.

This mattered enough to fix now, ahead of Fase 4.6's item 3 (a username
directory extending the relay, explicitly designed to make finding a
node's address *easy on purpose*) — that feature would have turned "you'd
have to already know or guess someone's `nodeId`" into "look up anyone's
username, then hit their app-facing API directly."

## Decision
- **`requireLocal(Handler)`** (new, `server/lib/src/http/require_local.dart`):
  wraps a handler so it only runs for a request whose
  `request.context['shelf.io.connection_info']` (the `HttpConnectionInfo`
  `shelf_io`'s real socket-based `serve()` attaches) has a loopback
  `remoteAddress`. Anything else — a real non-loopback address, or the
  context key missing entirely — gets `403`.
- **The "missing entirely" case is deliberate, not an oversight**: a
  request that arrives through `RelayClient._handle()` is a synthetic
  `Request` built by hand from a relay-tunnel message, with no real
  socket behind it, so it never carries this context key. Treating
  "missing" the same as "not loopback" means an app-facing route stays
  unreachable through the relay too — exactly right, since the relay
  exists for friend-to-friend network traffic, never "my own app talking
  to my own local server."
- **Wrapped wholesale**: `buildSoulseekRouter`, `buildLibraryRouter`,
  `buildPlaylistRouter` — every route in each is app-facing (their
  *inbound* call is always the local app, even where the *handler itself*
  makes an outbound call to a friend, e.g. the library router's
  friend-shares proxy or playlist sync).
- **Wrapped selectively, inside `buildFederationRouter`**: `POST
  /pairing-codes`, `GET /friends`, `DELETE /friends/<nodeId>`, `PATCH
  /friends/<nodeId>`, `GET /friends/<nodeId>/status`.
- **Left untouched, must stay network-reachable**: `POST /friends`
  (pairing-code redemption — what a friend's server calls directly),
  `GET /ping` (already behind `RequestVerifier`), and the entirety of
  `buildSharingFederationRouter` (`/api/v1/sharing/`).

## A regression this caused, and the fix: an API-key escape hatch
The loopback-only design above broke a real, documented, previously
working feature: `docs/self-hosting.md` explicitly describes running
Musicat Server on a separate machine (NAS/VPS, via Docker Compose) and
pointing the app at it "wherever this stack is reachable" — not
necessarily the same device. Found and flagged before this ever shipped,
not after. Jorge's decision: keep loopback-only as the zero-config
default (which is what the now-standard embedded server, ADR 0040-0043,
always is), but add an explicit opt-in for genuine remote self-hosting,
mirroring this project's own existing `SLSKD_API_KEY` pattern.

- **`requireLocal` gains an optional `appApiKey` parameter.** A loopback
  request is allowed through unconditionally either way — no key ever
  required for the local/embedded case. A non-loopback request is let
  through only if `appApiKey` is configured *and* the request presents a
  matching value in an `X-Api-Key` header, compared with a constant-time
  check (SHA-256 both sides via `cryptography`, already a dependency and
  already used this way in `node_identity.dart`, then XOR-folded byte by
  byte with no early exit) rather than a plain `==` on a secret. Threaded
  through `startMusicatServer`/`buildFederationRouter` to every
  `requireLocal` call site; `bin/server.dart` reads it from a new
  `MUSICAT_APP_API_KEY` env var, documented in `.env.example`,
  `docker-compose.yml`, `server/README.md`, and `docs/self-hosting.md`.
- **App side**: `MusicatServerConfig` (Friends/federation) gains an
  `apiKey` field, shown in `_ServerConfigSheet` only in manual/remote mode
  (never for the embedded case, which never populates it at all).
  `FederationClient`/`SharingClient`/`JointPlaylistClient` send it as
  `X-Api-Key` on every call to *this device's own* server —
  deliberately never on `FederationClient.addFriend()`'s separate call to
  a *friend's* server, which has its own, unrelated pairing-code auth.
  The Soulseek-via-Musicat-Server path (`MusicatServerSoulseekClient`)
  reuses `SoulseekConfig`'s existing `apiKey` field rather than adding a
  second one — that field already existed for slskd's own key in "direct
  slskd" mode and was simply unused in "via Musicat Server" mode; since
  only one backend mode is ever active, its meaning is just mode-dependent
  now. Fixed a real UI bug found while wiring this up: the Soulseek
  settings screen had the API key field's visibility inverted (hidden
  exactly in "via Musicat Server" mode, the one case that would now need
  it) — corrected alongside this change.

## Consequences
- `dart analyze`/`dart test` clean, 196 passed (182 before this ADR's work
  began) on the server side, and 217 passed on the app side — verified
  directly, not just from the implementing agents' reports; reviewed each
  round's actual diff line by line before running anything.
- **Verified for real, at the socket level, all four scenarios that
  actually matter**: `GET /api/v1/federation/friends` succeeds via
  `127.0.0.1` and gets `403` via this machine's real LAN IP (resolved
  live, same `NetworkInterface.list()` technique already used in
  `relay_client.dart`); `POST /friends` and `GET /api/v1/sharing/*` stay
  reachable via that same non-loopback address (ordinary application
  responses — 400, 401 — never this new 403); and, the case that mattered
  most, a request forwarded through a real `RelayHub`/`RelayClient` tunnel
  to an app-facing route gets `403`, while the same tunnel's request to a
  genuinely federation-facing route reaches its own object-level authz
  unaffected.
- No API shape changed for any existing success path — only a new
  failure mode (`403`) for a caller that was never supposed to be able to
  reach these routes in the first place. The app always talks to its own
  embedded/local server over loopback, so this is invisible in normal
  operation.
- With this closed, Fase 4.6's item 3 (username directory) no longer
  makes an existing gap materially worse by making addresses easy to
  find — clear to proceed with it next.
