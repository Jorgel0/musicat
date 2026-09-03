# 0046 — Let the embedded server actually use a relay

## Context
Both embedding rounds (ADR 0042 desktop, ADR 0043 Android) shipped with
an explicitly flagged gap: `startEmbeddedServerIfSupported`/
`_startAndroidEmbeddedServer` never passed a `relayUrl` to
`startMusicatServer`, even though that function has fully supported one
since ADR 0033. Without a relay, two embedded-server devices on
genuinely different networks can't reach each other at all — exactly
the problem ADR 0032-0035 already solved for the manual/CLI path
(`MUSICAT_RELAY_URL`), just never reachable from the embedded path.
Found when Jorge asked to actually test two devices across different
networks and the answer was "not yet, here's why."

## Decision
- **`MusicatServerConfig` gains `relayUrl`** (nullable, empty/unset by
  default — no baked-in default relay; the project stays self-hostable,
  not centralized around any one operator's instance). A new field in
  `_ServerConfigSheet`, shown only in embedded mode, with hint text
  covering both what it's for and the restart caveat below.
- **`embeddedServerProvider` reads it via a one-shot
  `loadMusicatServerConfigPreference()` call inside its own `build()`,
  never via `ref.watch` on the live, editable config provider.** This is
  the one design constraint that mattered most: watching the live config
  would make Riverpod re-run `build()` — restarting the whole embedded
  server, generating a new port, dropping live connections — on *every*
  unrelated settings edit, not just a relay URL change. Since
  `build()` never creates that dependency edge, there's nothing for
  Riverpod to invalidate it over; a changed relay URL only takes effect
  on the next app restart, the same way the CLI's own
  `MUSICAT_RELAY_URL` env var already only takes effect on process
  restart. Verified with a real `ProviderContainer` test: resolve the
  provider, save a changed config, confirm the resolved `AsyncValue` is
  the exact same instance (`build()` never re-ran).
- **Android's cross-isolate handoff mirrors the existing `dataDir`
  pattern exactly** — resolved on the main isolate, handed to the
  background-service isolate via `SharedPreferences`
  (`_androidServerRelayUrlPrefsKey`), not a second, different mechanism.

## Consequences
- `flutter analyze`/`flutter test` clean, 231 passed (up from 224) —
  verified directly, diff reviewed line by line first.
- **Verified live, for real, against the actually-deployed relay**: ran
  the real app binary against an isolated temp home directory, confirmed
  no relay line at all with nothing configured, then configured
  `ws://178.60.174.231:8090/connect` (the real relay from ADR 0035) and
  confirmed the restarted app's own log showed `Relay: connected to
  ws://178.60.174.231:8090/connect...`, with `/api/v1/node` reporting it
  back correctly. This is the exact chain (persisted config →
  `embeddedServerProvider` → `startMusicatServer` → `RelayClient` →
  `/api/v1/node`) ADR 0037's relay-status row and ADR 0045's username
  feature already depend on — both now work for the embedded case with
  no changes of their own needed.
- A real circular import exists between `core/embedded_server/
  embedded_server.dart` and `features/friends/presentation/
  musicat_server_config_controller.dart` (the former needs
  `loadMusicatServerConfigPreference()`, which lives in the latter,
  which imports the former for `embeddedServerProvider`). Dart handles
  this correctly (no static-initialization cycle — the function isn't a
  top-level constant depending on another one), confirmed by clean
  `flutter analyze` and a full green test suite, but it's a real
  layering smell (`core/` reaching into `features/`) worth a cleanup —
  most likely moving `loadMusicatServerConfigPreference()`/
  `MusicatServerConfig` somewhere `core/` can depend on without the
  reverse edge. Not fixed here; flagged for a future pass, not urgent.
- Android's cross-isolate relay wiring could not be verified live in
  this environment (no Android device connected during this specific
  round) — code-reviewed and pattern-matched against the already
  real-device-verified `dataDir` handoff (ADR 0043), but worth a real
  on-device check before relying on it for an actual cross-network test
  on that platform.
- With this, a real cross-network test (two devices on genuinely
  different networks, both using the embedded server, no manual
  server/Termux setup at all) is now actually possible — the next
  natural real-world verification step for this whole Fase 4.6 arc.
