import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/embedded_server/embedded_server.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `getApplicationSupportDirectory()` normally goes through a platform
/// channel; `flutter test` has no native side to answer it -- same reason
/// `library_scanner_test.dart`/`downloads_controller_test.dart` each define
/// their own copy of this rather than mocking a channel.
class _TempDirPathProvider extends PathProviderPlatform {
  _TempDirPathProvider(this._path);
  final String _path;

  @override
  Future<String?> getApplicationSupportPath() async => _path;
}

void main() {
  group('embeddedServerProvider — no reactive restart', () {
    late Directory supportDir;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      supportDir = Directory.systemTemp.createTempSync(
        'musicat_embedded_server_provider_test_',
      );
      PathProviderPlatform.instance = _TempDirPathProvider(supportDir.path);
    });

    tearDown(() {
      supportDir.deleteSync(recursive: true);
    });

    test('stays resolved to the exact same AsyncValue after the persisted '
        'server config changes afterwards -- editing server settings (e.g. '
        'the relay URL) only ever takes effect on the *next* app restart, '
        "deliberately: embeddedServerProvider's own build() reads "
        '`loadMusicatServerConfigPreference()` directly (a one-shot '
        'SharedPreferences read) exactly once, rather than '
        '`ref.watch`ing the live, editable `musicatServerConfigControllerProvider` '
        '-- getting this wrong would restart the whole embedded server '
        '(new port, dropped connections) on every unrelated settings edit, '
        'the same bug class as ADR 0037/0039.', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(embeddedServerProvider.future);
      final resolved = container.read(embeddedServerProvider);
      expect(resolved.hasValue, isTrue);

      // Exactly what MusicatServerConfigController.save() does when the
      // user edits the relay URL field and taps "Save".
      await container
          .read(musicatServerConfigControllerProvider.notifier)
          .save(
            const MusicatServerConfig(
              host: '',
              port: 8080,
              myPublicAddress: '',
              useEmbeddedServer: true,
              relayUrl: 'ws://changed-after-resolve.example/connect',
            ),
          );
      // Confirms the edit really did persist (the thing
      // embeddedServerProvider's own build() would re-read from if it
      // incorrectly ran again) -- otherwise this test could pass
      // vacuously even with a broken save().
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('musicatServerRelayUrl'),
        'ws://changed-after-resolve.example/connect',
      );

      // Still the exact same AsyncValue instance: build() never re-ran,
      // so whatever embedded server this resolved to was never
      // restarted.
      expect(container.read(embeddedServerProvider), same(resolved));
    });
  });

  group('startEmbeddedServerIfSupported — relayUrl pass-through', () {
    test(
      'a configured relayUrl reaches startMusicatServer -- the '
      "musicat_server package's own tests already cover "
      "startMusicatServer's relay-connection handling itself; this only "
      'proves the app-side plumbing actually forwards the configured '
      'value at all (previously, before this round, no relayUrl was ever '
      'passed through here)',
      () async {
        final dataDir = Directory.systemTemp.createTempSync(
          'musicat_embedded_server_relay_test_',
        );
        addTearDown(() => dataDir.deleteSync(recursive: true));

        final logLines = <String>[];
        final previousDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) logLines.add(message);
        };

        MusicatServerHandle? handle;
        try {
          handle = await startEmbeddedServerIfSupported(
            dataDir: dataDir,
            relayUrl: 'ws://127.0.0.1:1/unreachable-relay-for-testing',
          );
        } finally {
          debugPrint = previousDebugPrint;
        }
        addTearDown(() => handle?.close());

        expect(handle, isNotNull);
        // Nothing is listening on that address, so the relay connection
        // itself fails -- what matters here is that startMusicatServer's
        // own relay log line names the *exact* relayUrl this call passed
        // in, proving it was actually forwarded rather than silently
        // dropped along the way.
        expect(
          logLines,
          contains(
            '[MusicatServer] Relay: could not connect to '
            'ws://127.0.0.1:1/unreachable-relay-for-testing (continuing '
            'without it)',
          ),
        );
      },
      skip: (Platform.isLinux || Platform.isWindows)
          ? false
          : 'startEmbeddedServerIfSupported only runs on Linux/Windows',
    );

    test(
      'an unset relayUrl runs without one, same as before this round '
      '(no regression to the no-relay-configured default)',
      () async {
        final dataDir = Directory.systemTemp.createTempSync(
          'musicat_embedded_server_no_relay_test_',
        );
        addTearDown(() => dataDir.deleteSync(recursive: true));

        final handle = await startEmbeddedServerIfSupported(dataDir: dataDir);
        addTearDown(() => handle?.close());

        expect(handle, isNotNull);
        expect(handle!.relayUrl, isNull);
      },
      skip: (Platform.isLinux || Platform.isWindows)
          ? false
          : 'startEmbeddedServerIfSupported only runs on Linux/Windows',
    );
  });
}
