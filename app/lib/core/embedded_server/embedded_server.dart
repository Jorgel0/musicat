import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether this platform can safely run a full HTTP server in-process
/// alongside the Flutter app for the whole app lifetime — Linux, Windows,
/// and (as of this round) Android. On Linux/Windows this runs directly in
/// the app's own main isolate/process. On Android, where the OS can
/// suspend/kill the app process independently of whether a user thinks
/// it's "running", it instead runs inside a real Android background
/// service (`flutter_background_service`), started in a plain
/// (non-foreground) mode on every app launch and promoted to a genuine
/// foreground service (persistent notification) only once this device has
/// at least one friend — see `android_background_reachability_controller.dart`
/// (`features/friends/presentation/`) for that promotion logic, and
/// `_startAndroidEmbeddedServer` below for how the server itself gets
/// started there. iOS isn't a target of this app at all yet (see
/// `docs/adr/0001-flutter-multiplatform.md`).
bool get embeddedServerSupported =>
    Platform.isLinux || Platform.isWindows || Platform.isAndroid;

/// Starts this device's own embedded Musicat Server directly in-process,
/// wired straight into the `musicat_server` package's own
/// `startMusicatServer` — the exact same server implementation
/// `bin/server.dart` (the CLI/Docker/self-hosting path) runs, per that
/// function's own doc comment. Desktop only (Linux/Windows): Android needs
/// a real background-service isolate instead — see
/// `_startAndroidEmbeddedServer`, which `embeddedServerProvider` calls
/// instead of this on Android. Returns `null` immediately, without
/// starting anything, on any other platform.
///
/// Soulseek ([SlskdConfig]) is deliberately left unconfigured (the
/// `musicat_server` default): wiring the embedded server to this app's own
/// separately-configured Soulseek backend is out of scope for this round.
/// No relay fallback ([relayUrl]) is configured either — there's no UI yet
/// for a desktop user to set one for *this* (embedded) server specifically
/// (a manually self-hosted server's relay is set via an environment
/// variable the CLI reads, which doesn't apply here); flagged as an open
/// question for a future round rather than guessed at.
Future<MusicatServerHandle?> startEmbeddedServerIfSupported({
  required Directory dataDir,
}) async {
  if (!(Platform.isLinux || Platform.isWindows)) return null;

  return startMusicatServer(
    dataDir: dataDir,
    // 0, not the runtime's own default of 8080: a desktop user may well
    // already be running a *separate*, non-embedded Musicat Server on the
    // standard port on this same machine (e.g. this repo's own
    // docker-compose self-hosting path, docs/self-hosting.md) — binding a
    // fixed port here would make embedding fail outright to start for
    // exactly the people most likely to already have one. `0` lets the OS
    // assign a free port instead; the real one is read back from
    // `MusicatServerHandle.port`.
    port: 0,
    // Same operator-facing status lines `bin/server.dart` prints (identity,
    // NAT candidate, relay status, listening port) — routed through
    // `debugPrint` (stripped from release builds) rather than bare `print`,
    // since this now runs inside the Flutter app's own process/console
    // rather than a dedicated CLI one.
    onLog: (message) => debugPrint('[MusicatServer] $message'),
  );
}

/// Where the embedded server keeps its own data (node identity — ADR
/// 0015, must stay stable across restarts —, friends, shared-track/
/// joint-playlist stores): a dedicated subdirectory of this app's own
/// `path_provider` support directory, kept apart from the app's Drift
/// database and downloaded files. Mirrors the same `path_provider` usage
/// already in `library_scanner.dart`/`shared_track_download.dart`.
///
/// Always called from the main isolate (see `embeddedServerProvider`
/// below) — on Android, its resolved path is then handed to the
/// background-service isolate via [SharedPreferences] rather than calling
/// `path_provider` a second time from inside that isolate.
Future<Directory> embeddedServerDataDir() async {
  final supportDir = await getApplicationSupportDirectory();
  final dir = Directory(p.join(supportDir.path, 'musicat_server'));
  await dir.create(recursive: true);
  return dir;
}

/// The subset of a running embedded server's info the rest of the app
/// actually needs — deliberately not [MusicatServerHandle] itself: that
/// class's constructor is private to `musicat_server`, so a test can't
/// build one directly to feed [embeddedServerProvider] a fake "already
/// started" value; this small, app-owned type can be constructed freely.
/// It also happens to be exactly what's left of [MusicatServerHandle]
/// once it's crossed the isolate boundary from Android's background
/// service (a bare `port` int, sent back over `invoke()`/`on()`) — see
/// `_startAndroidEmbeddedServer`. If a future round needs more of the
/// handle (e.g. calling `.close()` from a "restart my server" UI action),
/// extend this rather than exposing [MusicatServerHandle] directly through
/// the provider (which wouldn't even be possible on Android, since
/// isolates can't share arbitrary Dart objects like that at all).
class EmbeddedServerInfo {
  const EmbeddedServerInfo({required this.port});

  /// The real bound port ([MusicatServerHandle.port]) — never the literal
  /// `0` passed to [startEmbeddedServerIfSupported]/[_startAndroidEmbeddedServer].
  final int port;
}

// --- Android background-service wiring -------------------------------

/// SharedPreferences key this device's manual "keep reachable in the
/// background" override is persisted under (see
/// `android_background_reachability_controller.dart`,
/// `AndroidBackgroundReachabilityOverrideController`). Exposed here, in
/// this lower-level file, rather than owned entirely by that
/// presentation-layer controller, because [_startAndroidEmbeddedServer]
/// below needs to read it too, at the exact moment it decides whether the
/// background service should start in real foreground mode from this very
/// first instant (see that method's own comment for why this can't just
/// be handled by the same runtime `invoke()`/`on()` toggle the live
/// friend-count-driven promotion uses).
const androidBackgroundReachabilityOverrideKey =
    'androidBackgroundReachabilityOverride';

/// SharedPreferences key for the last friend-count-derived "should this
/// device be reachable in the background" truth this app has actually
/// observed (see `android_background_reachability_controller.dart`) —
/// kept fresh every time that's known (in practice, only while the
/// Friends screen is open, since that's the only place a friend can ever
/// be added in the first place; see that file's own doc comment). Read
/// back here, at the next app launch, as the fallback initial foreground
/// mode when there's no explicit [androidBackgroundReachabilityOverrideKey]
/// — otherwise a returning user with existing friends who doesn't happen
/// to revisit the Friends screen on a given day would silently stop being
/// reachable that day, every day, which defeats the entire point of this
/// feature.
const androidLastKnownHasFriendsKey = 'androidLastKnownHasFriends';

const _androidServerDataDirPrefsKey = 'embeddedServerAndroidDataDirPath';
const _embeddedServerStartedEvent = 'musicatEmbeddedServerStarted';
const _embeddedServerFailedEvent = 'musicatEmbeddedServerFailed';
const _setForegroundEvent = 'musicatSetAsForeground';
const _setBackgroundEvent = 'musicatSetAsBackground';

/// Runs inside the dedicated background-service isolate `flutter_background_service`
/// manages on Android — a completely separate `FlutterEngine`/isolate from
/// the app's own main one, sharing only the OS process (so a `localhost`
/// socket bound here is still reachable from the main isolate's own HTTP
/// calls). Must be a top-level or static function per
/// `AndroidConfiguration.onStart`'s own doc comment (verified against the
/// resolved flutter_background_service_platform_interface 5.1.2 source);
/// `@pragma('vm:entry-point')` keeps it reachable in a release build,
/// where tree-shaking would otherwise assume nothing calls it (it's only
/// ever invoked by the native Android side, by callback handle, never by
/// any Dart call site in this codebase).
@pragma('vm:entry-point')
void _androidEmbeddedServerOnStart(ServiceInstance service) async {
  // Registers this isolate's own copy of every plugin the main app uses
  // (`shared_preferences` and `musicat_server`'s own dependencies among
  // them) — required any time Dart code needs a platform channel from a
  // background isolate/engine that isn't the one `main()` started. See
  // the flutter_background_service README's own example `onStart`.
  DartPluginRegistrant.ensureInitialized();

  // The data directory was resolved by `path_provider` on the *main*
  // isolate before this service was even started (see
  // `_startAndroidEmbeddedServer`) and handed in via `SharedPreferences`
  // rather than calling `path_provider` again from here — deliberately,
  // per this feature's own brief: calling a plugin like `path_provider`
  // from inside a background isolate isn't something to do without
  // actually verifying it's safe for the resolved plugin version, and
  // `SharedPreferences` (already relied on elsewhere across an isolate
  // boundary by nothing else in this app, but a plain, well-understood,
  // Context-only Android plugin with no Activity dependency) is a safer,
  // simpler way to hand a single already-resolved string across than
  // re-deriving it here.
  final prefs = await SharedPreferences.getInstance();
  final dataDirPath = prefs.getString(_androidServerDataDirPrefsKey);
  if (dataDirPath == null) {
    service.invoke(_embeddedServerFailedEvent, {
      'error': 'no data directory was configured before starting',
    });
    return;
  }

  try {
    final handle = await startMusicatServer(
      dataDir: Directory(dataDirPath),
      // Same reasoning as the desktop path: 0 lets the OS assign a free
      // port, read back below.
      port: 0,
      onLog: (message) => debugPrint('[MusicatServer/bg] $message'),
    );
    service.invoke(_embeddedServerStartedEvent, {'port': handle.port});
  } catch (e) {
    service.invoke(_embeddedServerFailedEvent, {'error': e.toString()});
    return;
  }

  // Live foreground/background toggling for the rest of this service's
  // run — e.g. once this device's first friend gets added mid-session
  // (see `android_background_reachability_controller.dart`). Deliberately
  // registered only now, after the one-shot startup logic above: by the
  // time the main isolate could possibly have anything to say over this
  // event pipe, it necessarily already knows this server's own port
  // (through the `_embeddedServerStartedEvent` just sent, which is what
  // `federationClientProvider` — needed for any friend-count check at all
  // — is built from), which itself can only happen strictly after this
  // point. `invoke()`/`on()` messages sent before a listener is
  // registered are silently dropped (see
  // `FlutterBackgroundServicePlugin`'s own `sendData` handling in the
  // resolved flutter_background_service_android 6.3.1 source), so this
  // ordering isn't incidental.
  if (service is AndroidServiceInstance) {
    service.on(_setForegroundEvent).listen((_) {
      service.setAsForegroundService();
    });
    service.on(_setBackgroundEvent).listen((_) {
      service.setAsBackgroundService();
    });
  }
}

/// Starts this device's own embedded Musicat Server on Android, inside a
/// real `flutter_background_service`-managed background service — not
/// directly in-process like [startEmbeddedServerIfSupported] does on
/// desktop, since Android can suspend/kill the app's own process
/// (including anything running in it) independently of whether the user
/// thinks the app is "running". The service itself always starts in
/// *some* mode the very first time (foreground or plain) — see
/// `isForegroundMode` below — and can be toggled between the two later at
/// runtime by [setAndroidBackgroundReachable] (a real, resolved capability
/// of this plugin version, not something this app invented — see
/// `AndroidServiceInstance.setAsForegroundService`/`setAsBackgroundService`
/// in the resolved flutter_background_service_android 6.3.1 source).
Future<EmbeddedServerInfo?> _startAndroidEmbeddedServer({
  required Directory dataDir,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_androidServerDataDirPrefsKey, dataDir.path);

  // The very first foreground/background mode this service starts in,
  // decided *before* it even exists: an explicit manual override always
  // wins; absent one, fall back to the last friend-count truth this app
  // actually observed (see `androidLastKnownHasFriendsKey`'s own doc
  // comment for why that fallback matters, rather than just always
  // starting plain and waiting for a live check that might never run this
  // session). This is deliberately *not* routed through the same
  // `invoke()`/`on()` pipe [setAndroidBackgroundReachable] uses for later
  // runtime changes: a message sent that early would race the background
  // isolate's own listener registration inside `_androidEmbeddedServerOnStart`
  // (which only happens after `startMusicatServer` itself resolves) and
  // could be silently dropped — passing it as `configure()`'s own
  // `isForegroundMode` instead applies natively, with no such race, before
  // the service isolate is even created.
  final override = prefs.getBool(androidBackgroundReachabilityOverrideKey);
  final lastKnownHasFriends =
      prefs.getBool(androidLastKnownHasFriendsKey) ?? false;
  final initialForegroundMode = override ?? lastKnownHasFriends;

  final service = FlutterBackgroundService();
  // Subscribed before `configure()`/starting the service, not after: both
  // of these are broadcast through a stream that already exists as soon
  // as this app's own singleton copy of the plugin is constructed,
  // independently of `configure()` ever having run — see `on()`'s own
  // implementation in the resolved flutter_background_service_android
  // 6.3.1 source — so there's no risk of missing an event that arrives
  // before this method gets around to listening.
  final started = service.on(_embeddedServerStartedEvent).first;
  final failed = service.on(_embeddedServerFailedEvent).first;

  await service.configure(
    // iOS isn't a target of this app at all (see
    // `docs/adr/0001-flutter-multiplatform.md`) — this exists only
    // because `configure()`'s signature requires it unconditionally; it
    // never actually runs anywhere this app ships.
    iosConfiguration: IosConfiguration(autoStart: false),
    androidConfiguration: AndroidConfiguration(
      onStart: _androidEmbeddedServerOnStart,
      autoStart: true,
      autoStartOnBoot: false,
      isForegroundMode: initialForegroundMode,
      // connectedDevice, not dataSync: dataSync has a hard 6-hour-per-24-
      // hours runtime cap on Android 15 (this app's targetSdk) that would
      // force periodic self-stops; connectedDevice has no such cap, and
      // its prerequisite permission (CHANGE_NETWORK_STATE, declared in
      // AndroidManifest.xml) is a normal/install-time permission, adding
      // no extra consent dialog beyond POST_NOTIFICATIONS (already
      // requested today for audio_service's own playback notification).
      foregroundServiceTypes: const [AndroidForegroundType.connectedDevice],
      initialNotificationTitle: 'Musicat',
      initialNotificationContent: 'Available for your friends to reach',
    ),
  );

  final result = await Future.any<Map<String, dynamic>?>([
    started,
    failed,
    // A generous timeout, not a tight one: NAT traversal/STUN can
    // genuinely take real time (see the desktop path's own comments), and
    // this also has to cover real Android service/engine cold-start
    // overhead the desktop path doesn't have at all.
  ]).timeout(const Duration(seconds: 30), onTimeout: () => null);

  final port = result?['port'];
  if (port is! num) return null;
  return EmbeddedServerInfo(port: port.toInt());
}

/// Toggles this device's *already-running* Android background service
/// between plain and foreground-service mode at runtime — see
/// `AndroidServiceInstance.setAsForegroundService`/`setAsBackgroundService`
/// in the resolved flutter_background_service_android 6.3.1 source: both
/// are real, officially-supported runtime toggles this plugin version
/// already provides, not something this app invented. Routed through
/// `invoke()`/`on()` since only the background isolate itself — not this
/// one — can call them directly (see `_androidEmbeddedServerOnStart`
/// above). A no-op on every platform other than Android, including in
/// `flutter test` (which never has a real
/// `FlutterBackgroundServicePlatform.instance` registered, and would
/// otherwise throw the moment anything calls `FlutterBackgroundService()`
/// on it).
void setAndroidBackgroundReachable(bool reachable) {
  if (!Platform.isAndroid) return;
  FlutterBackgroundService().invoke(
    reachable ? _setForegroundEvent : _setBackgroundEvent,
  );
}

/// Starts the embedded server once for the whole app run and caches the
/// result — a plain (non-`autoDispose`) [FutureProvider], so once
/// something reads it, it keeps running until the app process exits;
/// nothing tears it down or restarts it per screen visit.
///
/// This is a [FutureProvider] whose `build()` *is* the startup work,
/// rather than some side effect kicked off from a widget's `initState`/
/// `build()`/a router `redirect` — that pattern is exactly what caused two
/// real, previously-shipped crashes in this app (see ADR 0037/0039: a
/// synchronous `state = ...` write from inside another provider's
/// `build()`, before Riverpod had finished initializing that provider's
/// own state slot). Nothing here ever writes to another provider's state;
/// `bootstrap()` merely calls `container.read(embeddedServerProvider)`
/// right after creating the container (before `runApp`) to kick this off
/// eagerly without awaiting it, so it's already underway well before the
/// Friends screen would need it — anything that watches it afterward
/// (`effectiveMusicatServerConfigProvider`) just observes the same
/// [AsyncValue] progress from `loading` to `data`, the normal way any
/// [FutureProvider] is consumed.
final embeddedServerProvider = FutureProvider<EmbeddedServerInfo?>((ref) async {
  final dataDir = await embeddedServerDataDir();
  if (Platform.isAndroid) {
    return _startAndroidEmbeddedServer(dataDir: dataDir);
  }
  final handle = await startEmbeddedServerIfSupported(dataDir: dataDir);
  return handle == null ? null : EmbeddedServerInfo(port: handle.port);
});
