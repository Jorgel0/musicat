import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Whether this platform can safely run a full HTTP server in-process
/// alongside the Flutter app for the whole app lifetime — desktop only for
/// now. Android has real background-execution restrictions a plain
/// in-process server doesn't account for (the OS can suspend/kill the app
/// process independently of whether a user thinks it's "running"); a later
/// round adds a proper foreground/background service there (see the
/// feature brief this shipped under). iOS isn't a target of this app at
/// all yet (see `docs/adr/0001-flutter-multiplatform.md`).
bool get embeddedServerSupported => Platform.isLinux || Platform.isWindows;

/// Starts this device's own embedded Musicat Server, wired straight into
/// the `musicat_server` package's own `startMusicatServer` — the exact
/// same server implementation `bin/server.dart` (the CLI/Docker/
/// self-hosting path) runs, per that function's own doc comment. Returns
/// `null` immediately, without starting anything, on any platform where
/// [embeddedServerSupported] is `false`.
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
  if (!embeddedServerSupported) return null;

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
/// If a future round needs more of the handle (e.g. calling `.close()`
/// from a "restart my server" UI action), extend this rather than
/// exposing [MusicatServerHandle] directly through the provider.
class EmbeddedServerInfo {
  const EmbeddedServerInfo({required this.port});

  /// The real bound port ([MusicatServerHandle.port]) — never the literal
  /// `0` passed to [startEmbeddedServerIfSupported].
  final int port;
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
  final handle = await startEmbeddedServerIfSupported(dataDir: dataDir);
  return handle == null ? null : EmbeddedServerInfo(port: handle.port);
});
