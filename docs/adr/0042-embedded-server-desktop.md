# 0042 — Embed Musicat Server on desktop, no separate process

## Context
Second item of Fase 4.6 (see the plan file), split into a desktop slice
(this ADR) and a follow-up Android slice (needs `flutter_background_service`
and real device risk — separate round, separate ADR). Motivated directly
by ADR 0040/0041: running "your own Musicat Server" has always meant a
separate process the user installs and starts by hand (Docker, or Termux
on Android). Jorge asked for it embedded in the app itself — install one
thing, and it's simultaneously the player and its own reachable node.

## Decision
- **`server/lib/musicat_server_runtime.dart`** (new): `bin/server.dart`'s
  `main()` extracted into a reusable `startMusicatServer({dataDir, port,
  udpPort, relayUrl, slskdConfig, onLog})` → `MusicatServerHandle`
  (`identity`, `publicKeyBase64`, the real bound `port`, `relayUrl`,
  `close()`). Pure refactor, no behavior change — `bin/server.dart` is now
  a ~30-line CLI wrapper reading the same env vars it always did and
  calling this. Verified the CLI/Docker/self-hosting path is unaffected:
  real smoke test (start, `curl /api/v1/node`, stop) after the extraction,
  identical output to before.
- **`app/` depends on `server/` directly** (`musicat_server: {path:
  ../server}`) — the exact same production classes, not a
  reimplementation. Every dependency in `server/pubspec.yaml` is pure
  Dart, so this needed no isolate/plugin-boundary workarounds.
- **`core/embedded_server/embedded_server.dart`**: `embeddedServerSupported`
  (`Platform.isLinux || Platform.isWindows` — Android is the follow-up
  round, needs a background-execution strategy this doesn't have yet),
  `startEmbeddedServerIfSupported` (calls `startMusicatServer` with
  `port: 0` — deliberately not the CLI's default `8080`, so an embedded
  instance never fails to start just because the same machine also runs a
  separately self-hosted one on the standard port), and
  `embeddedServerDataDir()` (`path_provider`'s
  `getApplicationSupportDirectory()`, a dedicated subdirectory, kept apart
  from the app's own Drift database).
- **`embeddedServerProvider`**: a plain `FutureProvider` whose `build()`
  *is* the startup work, read once (not awaited) from `bootstrap()` before
  `runApp` via a manually-created `ProviderContainer` +
  `UncontrolledProviderScope` — the standard Riverpod pattern for
  pre-`runApp` async work that still shares state with the widget tree.
- **`effectiveMusicatServerConfigProvider`**: the one place embedded-vs-manual
  gets resolved — a plain synchronous `Provider` that only ever *reads*
  `embeddedServerProvider`'s `AsyncValue` via `.when(...)`, never writes to
  any provider's state. `MusicatServerConfig` itself stays Riverpod-unaware;
  it gained `useEmbeddedServer` (defaults to `true` on a fresh desktop
  install, `false` on Android or once a user has ever explicitly chosen),
  with `host`/`port` preserved untouched underneath so toggling back to
  manual mode restores exactly what was there before.
- **The manual/self-hosted path is unchanged and still fully supported**
  (NAS, VPS, Docker Compose) — `_ServerConfigSheet` gained a "Use the
  built-in server" toggle; switching it off restores the existing
  host/port/address fields as the source of truth exactly as before this
  ADR.
- **Deliberate care around a bug class this app has hit twice already**
  (ADR 0037, 0039: a synchronous provider write from inside a widget
  lifecycle callback — `build()`, `initState`, a router `redirect`,
  before Riverpod finished initializing that provider's own state).
  Nothing in this design writes to another provider's state at all —
  `embeddedServerProvider`'s startup work lives in its own `build()`,
  `effectiveMusicatServerConfigProvider` only reads it. Proved this with
  `ProviderContainer` tests mirroring the exact style that caught the
  prior two bugs: cold reads of the whole chain (including
  `friendsControllerProvider`, which now transitively depends on it)
  while the embedded server is deliberately never-resolving, confirmed to
  never throw.

## Consequences
- `dart analyze`/`dart test` (server, 165 passed) and `flutter analyze`/
  `flutter test` (app, 189 passed) clean — verified directly, including a
  real isolated Dart snippet to double-check an unrelated private-named-
  constructor-parameter question raised during review (false alarm — the
  code was correct; documented here only as a reminder to verify surprising
  reads against the compiler rather than trust intuition).
- **Verified live, independently, not just from the implementing agent's
  report**: launched the real app three separate times (twice by the
  agent, once by me) and confirmed the exact same `nodeId`
  (`a447d96e...a459a6f`) every time — real proof identity survives
  restarts (ADR 0015) now that `dataDir` is a stable `path_provider`
  location. Confirmed the embedded server is genuinely reachable via a
  direct `curl` against the real logged port, matching what the app's own
  UI would call.
- Not yet verified live: clicking through the actual Friends screen in
  the running window to see the setup prompt disappear — this dev
  environment has no working input-automation tool (same gap noted in
  ADR 0037). Covered instead by widget tests exercising the same gating
  logic against a resolved config, plus the direct HTTP proof above that
  the backend those tests assume is genuinely live.
- Still open, explicitly out of scope here: Android embedding (needs
  `flutter_background_service`, a foreground-service type decision, a
  persistent-notification UX call — all already designed in the plan
  file, next round); no relay fallback configured for an embedded desktop
  instance yet (no UI exists for it); Soulseek stays unwired to the
  embedded instance (a separate, pre-existing feature, untouched).
