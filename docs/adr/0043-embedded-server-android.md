# 0043 — Embed Musicat Server on Android, no Termux

## Context
Second half of Fase 4.6's item 2 (ADR 0042 did desktop). Android is the
platform that actually motivated this whole item — ADR 0040's real
two-device test needed Termux, manual Dart install, and hit a real
storage-sandbox permission gap along the way. This closes that: the
embedded server now runs on Android too, without a separate app.

## Decision
- **`flutter_background_service` (^5.1.0)** runs `startMusicatServer(...)`
  inside a dedicated background-service isolate — a genuine Android
  foreground-service-capable isolate, not a plain in-process call like
  desktop, since Android can suspend/kill the app's own process
  independently of whether the user thinks it's "running."
- **Foreground-service type `connectedDevice`, not `dataSync`** — already
  decided in the plan (Android 15's `dataSync` has a hard 6h/24h runtime
  cap that would force periodic self-stops; `connectedDevice` has none,
  and its prerequisite permission, `CHANGE_NETWORK_STATE`, is
  install-time, adding no extra consent dialog beyond `POST_NOTIFICATIONS`
  already requested today for `audio_service`'s own notification).
- **The chicken-and-egg problem resolved deliberately**: the server
  starts on every app launch, in whatever mode (plain or foreground) the
  last known state calls for — never gated on friend count, since pairing
  your very first friend needs a running, locally-reachable server before
  any friend exists. Only the *persistent, background-surviving*
  reachability (the real foreground service, with its unavoidable
  notification) is gated: automatic once this device has ≥1 friend, with
  a manual override toggle (mirroring desktop's "Use the built-in server"
  switch) for a user who wants it on/off regardless.
- **Cross-isolate wiring, each piece verified against the actually
  resolved plugin source rather than assumed**:
  - `path_provider`'s data directory is resolved once on the main isolate
    and handed to the background isolate via `SharedPreferences` — not
    re-resolved inside the background isolate.
  - `AndroidServiceInstance.setAsForegroundService()`/
    `setAsBackgroundService()` (confirmed real methods in the resolved
    `flutter_background_service_android` 6.3.1) let the background
    isolate toggle its own mode live, driven by `invoke()`/`on()`
    messages from the main isolate the moment a friend count changes.
  - The service's *initial* mode is set directly via `configure()`'s own
    `isForegroundMode` parameter (from persisted state, before the
    isolate even exists) rather than relying on that runtime toggle at
    startup — reviewed a possible race between the two mechanisms and
    confirmed it's harmless either way, since `configure()` already
    guarantees the correct starting mode regardless of whether a
    redundant/racy `invoke()` call lands before or after.
- **`AndroidManifest.xml`**: `FOREGROUND_SERVICE_CONNECTED_DEVICE`/
  `CHANGE_NETWORK_STATE` permissions, and a `<service>` entry adding only
  `foregroundServiceType="connectedDevice"` to the plugin's own
  `id.flutter.flutter_background_service.BackgroundService` (confirmed
  the fully-qualified name against the plugin's own manifest — Android's
  manifest merge fills in the rest of that service's attributes from the
  plugin's declaration unchanged). `audio_service`'s existing
  service/receiver and the `musicat://` deep-link intent-filter are
  untouched.

## Consequences
- `dart analyze`/`flutter analyze`/`flutter test` clean, 200/200 passing.
- **Verified live on a real device (Android 13, API 33)**, independently,
  twice — once during implementation, once again in review: app launches
  without crashing; a pairing code generates with zero friends (no
  chicken-and-egg problem); adding a first friend makes the persistent
  notification appear; a cold restart correctly comes back in foreground
  mode from persisted state before the Friends screen even reloads;
  backgrounding the app for 60+ seconds leaves the server genuinely
  reachable (confirmed via `adb forward` + `curl` from the host); the
  manual override toggle works both directions; `audio_service`'s
  playback notification and the `musicat://` deep link both still work.
- **A benign plugin-internal warning, investigated and confirmed
  harmless, not a bug**: `DartPluginRegistrant.ensureInitialized()`
  inside the background isolate re-triggers
  `flutter_background_service_android`'s own platform-interface
  registration, which deliberately throws
  (`FlutterBackgroundServiceAndroid`'s factory constructor checks an
  internal `_isMainIsolate` flag) because that class is meant for the
  main isolate only — Flutter's generated plugin registrant catches this
  per-plugin, so it never blocks any other plugin's registration
  (confirmed: the server started correctly with the right identity/NAT/
  port in the same run this warning printed in). Traced to the exact
  line in the resolved package source rather than assumed benign.
- **A real, pre-existing gap surfaced, not introduced by this round**:
  this app has never requested `POST_NOTIFICATIONS` at runtime. On a
  fresh install it defaults to denied, silently suppressing *both*
  `audio_service`'s playback notification and this round's new
  persistent one until granted manually. Worth its own round: request it
  at a sensible moment (first playback, or app launch) via
  `permission_handler` (already a dependency).
- Not independently verifiable in this environment: OEM/ROM-specific
  battery-optimization behavior beyond this one device/session — an
  accepted, documented limitation (see the plan file), not something any
  amount of app-side code can fully close.
- With this, item 2 of Fase 4.6 (embedded server, both platforms) is
  done. Next: item 3, the username directory — plus the still-open
  decision on when to fix the pre-existing app-facing-routes-have-no-auth
  gap (ADR 0041's Consequences), which matters more once item 3 makes
  addresses easy to find on purpose.
