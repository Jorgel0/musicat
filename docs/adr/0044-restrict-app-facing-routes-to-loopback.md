# 0044 — Restrict app-facing routes to loopback callers

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

## Consequences
- `dart analyze`/`dart test` clean, 186 passed (up from 182) — verified
  directly, not just from the implementing agent's report; reviewed the
  actual diff line by line first.
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
