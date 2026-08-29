import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/embedded_server/embedded_server.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _manual = MusicatServerConfig(
  host: 'nas.example',
  port: 9090,
  myPublicAddress: 'me.example:9090',
  myDisplayName: 'My Name',
);

const _embedded = MusicatServerConfig(
  host: '',
  port: 8080,
  myPublicAddress: 'me.example:8080',
  myDisplayName: 'My Name',
  useEmbeddedServer: true,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('loadMusicatServerConfigPreference', () {
    test('defaults useEmbeddedServer to whether this platform supports it, on '
        'a fresh install (the key was never saved)', () async {
      final config = await loadMusicatServerConfigPreference();
      expect(config.useEmbeddedServer, embeddedServerSupported);
    });

    test('once explicitly saved, the persisted choice wins regardless of '
        'platform support', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('musicatServerUseEmbeddedServer', false);

      final config = await loadMusicatServerConfigPreference();
      expect(config.useEmbeddedServer, isFalse);
    });

    test('a persisted explicit true is honored too', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('musicatServerUseEmbeddedServer', true);

      final config = await loadMusicatServerConfigPreference();
      expect(config.useEmbeddedServer, isTrue);
    });
  });

  group('MusicatServerConfigController.save', () {
    test('persists useEmbeddedServer', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(musicatServerConfigControllerProvider.notifier)
          .save(_manual.copyWith(useEmbeddedServer: true));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('musicatServerUseEmbeddedServer'), isTrue);
    });

    test('persists apiKey, and loadMusicatServerConfigPreference reads it '
        'back', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(musicatServerConfigControllerProvider.notifier)
          .save(_manual.copyWith(apiKey: 'remote-secret'));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('musicatServerApiKey'), 'remote-secret');

      final loaded = await loadMusicatServerConfigPreference();
      expect(loaded.apiKey, 'remote-secret');
    });

    test('an unset/empty apiKey persists and loads back as null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(musicatServerConfigControllerProvider.notifier)
          .save(_manual);

      final loaded = await loadMusicatServerConfigPreference();
      expect(loaded.apiKey, isNull);
    });
  });

  group('effectiveMusicatServerConfigProvider — manual mode', () {
    test('passes the raw config through unchanged, and never touches '
        'embeddedServerProvider at all (no reason to start/watch an embedded '
        'server nobody asked to use)', () {
      var embeddedProviderBuilt = false;
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_manual),
          ),
          embeddedServerProvider.overrideWith((ref) {
            embeddedProviderBuilt = true;
            return Future.value(null);
          }),
        ],
      );
      addTearDown(container.dispose);

      final effective = container.read(effectiveMusicatServerConfigProvider);

      expect(effective, _manual);
      expect(effective.isConfigured, isTrue);
      expect(effective.baseUrl, 'http://nas.example:9090');
      expect(embeddedProviderBuilt, isFalse);
    });
  });

  group('effectiveMusicatServerConfigProvider — embedded mode', () {
    test('is not configured yet while the embedded server is still starting '
        '(and a cold read never throws — regression coverage for the same '
        'uninitialized-provider bug class as ADR 0037/0039, now reachable '
        'through this new provider chain)', () {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_embedded),
          ),
          // Never completes -- simulates "still starting".
          embeddedServerProvider.overrideWith(
            (ref) => Completer<EmbeddedServerInfo?>().future,
          ),
        ],
      );
      addTearDown(container.dispose);

      final effective = container.read(effectiveMusicatServerConfigProvider);

      expect(effective.isConfigured, isFalse);
      // myPublicAddress/myDisplayName are unrelated to the embedded
      // server's own startup and stay available even before it's ready.
      expect(effective.myPublicAddress, 'me.example:8080');
      expect(effective.myDisplayName, 'My Name');
    });

    test(
      'substitutes host/port for the embedded server once it resolves, '
      'preserving myPublicAddress/myDisplayName from the raw config',
      () async {
        final container = ProviderContainer(
          overrides: [
            musicatServerConfigControllerProvider.overrideWith(
              () => MusicatServerConfigController(_embedded),
            ),
            embeddedServerProvider.overrideWith(
              (ref) async => const EmbeddedServerInfo(port: 54321),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Wait for embeddedServerProvider's Future to actually resolve.
        await container.read(embeddedServerProvider.future);

        final effective = container.read(effectiveMusicatServerConfigProvider);
        expect(effective.isConfigured, isTrue);
        expect(effective.host, 'localhost');
        expect(effective.port, 54321);
        expect(effective.baseUrl, 'http://localhost:54321');
        expect(effective.myPublicAddress, 'me.example:8080');
        expect(effective.myDisplayName, 'My Name');
      },
    );

    test('stays not configured when embedding resolves to null (unsupported '
        'platform or failed to start)', () async {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_embedded),
          ),
          embeddedServerProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);

      await container.read(embeddedServerProvider.future);

      expect(
        container.read(effectiveMusicatServerConfigProvider).isConfigured,
        isFalse,
      );
    });

    test('stays not configured (and does not throw) if starting the embedded '
        'server throws', () async {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_embedded),
          ),
          embeddedServerProvider.overrideWith(
            (ref) async => throw StateError('boom'),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Let the FutureProvider settle into its error state.
      await container
          .read(embeddedServerProvider.future)
          .catchError((_) => null);

      expect(
        container.read(effectiveMusicatServerConfigProvider).isConfigured,
        isFalse,
      );
    });
  });

  group('effectiveMusicatServerConfigProvider — reacts to toggling', () {
    test('flipping useEmbeddedServer on/off via save() switches which config '
        'is effective, without needing to recreate the container', () async {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_manual),
          ),
          embeddedServerProvider.overrideWith(
            (ref) async => const EmbeddedServerInfo(port: 12345),
          ),
        ],
      );
      addTearDown(container.dispose);
      // A real widget's ref.watch plays the role this listener does
      // here, keeping the derived provider alive across the change
      // (same pattern as friends_controller_test.dart).
      final subscription = container.listen(
        effectiveMusicatServerConfigProvider,
        (a, b) {},
      );
      addTearDown(subscription.close);

      expect(
        container.read(effectiveMusicatServerConfigProvider).host,
        'nas.example',
      );

      await container
          .read(musicatServerConfigControllerProvider.notifier)
          .save(_manual.copyWith(useEmbeddedServer: true));
      await container.read(embeddedServerProvider.future);

      var effective = container.read(effectiveMusicatServerConfigProvider);
      expect(effective.host, 'localhost');
      expect(effective.port, 12345);

      await container
          .read(musicatServerConfigControllerProvider.notifier)
          .save(_manual);

      effective = container.read(effectiveMusicatServerConfigProvider);
      expect(effective.host, 'nas.example');
      expect(effective.port, 9090);
    });
  });

  group('effectiveMusicatServerConfigProvider — apiKey', () {
    test('is preserved unchanged in manual mode', () {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(
              _manual.copyWith(apiKey: 'remote-secret'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(effectiveMusicatServerConfigProvider).apiKey,
        'remote-secret',
      );
    });

    test('stays null for the embedded server, which never populates it '
        '(the UI never shows the field in that mode)', () async {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_embedded),
          ),
          embeddedServerProvider.overrideWith(
            (ref) async => const EmbeddedServerInfo(port: 54321),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(embeddedServerProvider.future);

      expect(
        container.read(effectiveMusicatServerConfigProvider).apiKey,
        isNull,
      );
    });
  });

  group('client providers derive from the effective config', () {
    test('federationClientProvider is null while embedding is starting', () {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_embedded),
          ),
          embeddedServerProvider.overrideWith(
            (ref) => Completer<EmbeddedServerInfo?>().future,
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(federationClientProvider), isNull);
    });

    test('friendsControllerProvider does not crash on a cold read while the '
        'embedded server is still starting (extends ADR 0037/0039 coverage '
        'to this new provider chain)', () async {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_embedded),
          ),
          embeddedServerProvider.overrideWith(
            (ref) => Completer<EmbeddedServerInfo?>().future,
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        friendsControllerProvider,
        (a, b) {},
      );
      addTearDown(subscription.close);

      final state = container.read(friendsControllerProvider);
      expect(state, const FriendsState());

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(friendsControllerProvider), const FriendsState());
    });
  });
}
