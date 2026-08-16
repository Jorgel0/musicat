# 0016 — Musicat Server wraps slskd: search and downloads

## Context
With node identity in place (ADR 0015), the next piece of Fase 3's "Hecho
cuando" bar is that the app can search/download exactly as in Fase 2, but
routed through Musicat Server instead of talking to `slskd` directly. That
means the server needs its own copy of the slskd-quirk-handling knowledge
`SlskdSoulseekClient` already encodes (ADR 0010): the blocking-POST/
live-GET search design, the nested downloads tree, the `[Flags]`-enum
transfer state string, and slskd's inconsistent error bodies.

## Decision
- **`SoulseekGateway`** (`server/lib/src/soulseek/soulseek_models.dart`) is
  the server-side mirror of the app's `SoulseekClient` interface (ADR
  0004): `isConnected`, `startSearch`/`getSearch`/`cancelSearch`,
  `enqueueDownload`/`getDownloads`/`cancelDownload`,
  `getDownloadsDirectory`. Same shape, same reasoning, now living
  server-side instead of app-side.
- **`SlskdGateway`** implements it against a real slskd instance, using
  `package:http` (ported from `SlskdSoulseekClient`'s `dio`-based logic —
  same fire-and-forget search POST, same tree-flattening, same transfer
  state flag collapsing). Configured via `SLSKD_HOST`/`SLSKD_PORT`/
  `SLSKD_API_KEY` environment variables (`SlskdConfig.fromEnvironment`).
- **The domain types the gateway produces are the response bodies the app
  will eventually consume** (`SoulseekSearch.toJson()`,
  `SoulseekTransfer.toJson()`, etc., with the exact field names
  `SoulseekSearch`/`SoulseekTransfer` already use app-side) — the quirk
  handling only needs to happen once, here, rather than being duplicated
  in every current or future client. A next slice's
  `MusicatServerSoulseekClient` should be a thin JSON-decoding shim, not a
  second copy of the parsing logic in `SlskdSoulseekClient`.
- **Routes** (`server/lib/src/soulseek/soulseek_routes.dart`), mounted at
  `/api/v1/soulseek/`:
  - `GET /status` → `{"connected": bool}`
  - `POST /searches` (`{"query": "..."}`) → `201 {"searchId": "..."}`
  - `GET /searches/<id>` → the search, already parsed
  - `DELETE /searches/<id>` → `204`
  - `POST /downloads` (`{"username", "files": [...]}`) → `201`
  - `GET /downloads` → the flattened transfer list
  - `DELETE /downloads/<username>/<id>` → `204`
  - `GET /downloads-directory` → `{"directory": "..." | null}`
  - Errors: `SoulseekNotConnectedException` → 409,
    `SoulseekUserOfflineException` → 404, any other
    `SoulseekGatewayException` forwards its real upstream status code
    (falling back to 502 if that code isn't a valid HTTP error status) —
    same semantic mapping the app's Search/Downloads screens already
    handle from `SlskdSoulseekClient`, so the next slice's client swap
    shouldn't need new error-handling UI.

## Consequences
- Unit-tested against a fake HTTP layer
  (`test/soulseek/slskd_gateway_test.dart`, using `package:http`'s own
  `MockClient` rather than a hand-rolled fake, since — unlike `dio` in the
  app — `http` ships an official one) and against a fake `SoulseekGateway`
  for the route layer (`test/soulseek/soulseek_routes_test.dart`).
- **Caught a real bug via this testing, not just via inspection**:
  `isConnected()` initially built its request without attaching the
  `X-API-Key` header at all — copy-pasted from a spot in the port that
  predated the shared `_headers` getter being wired everywhere else. The
  gateway test asserting the header's presence failed immediately against
  the mock client, confirming the bug before it ever reached a real
  instance.
- **Verified against the real CT-hosted slskd** (`192.168.1.140:5030`,
  same instance ADR 0010 used) — deliberately with an invalid API key
  rather than a real one, so this could be verified without needing to
  retrieve a live secret over SSH: `GET /api/v1/soulseek/status` correctly
  forwarded slskd's real `401`, `GET /api/v1/soulseek/downloads-directory`
  degraded gracefully to `{"directory": null}` with `200` rather than
  throwing, and `POST /api/v1/soulseek/searches` surfaced the same real
  `401` (since `startSearch` checks `isConnected()` first). This confirms
  the real network path and error propagation work, not just the mocked
  logic — a full search/download round-trip against a *valid* login is
  still open, pending real slskd credentials.
- The app still has no code talking to Musicat Server yet — `SoulseekClient`/
  `SlskdSoulseekClient` (ADR 0010) are unchanged and still what the app
  uses directly. That swap, plus how Settings should let a user pick
  between "direct slskd" and "via Musicat Server" (or whether the direct
  path is retired outright), is deliberately left to a following slice
  rather than decided here.
