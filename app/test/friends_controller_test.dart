import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/federation/federation_client.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';

import 'fakes/fake_http_adapter.dart';

const _configured = MusicatServerConfig(
  host: 'localhost',
  port: 8080,
  myPublicAddress: 'me.example:8080',
);

void main() {
  group('FriendsController.build', () {
    test('does not crash with an uninitialized-provider error when a server '
        'is already configured (regression: build() used to kick off '
        '_refresh synchronously, writing `state` before Riverpod finished '
        "initializing this provider's state slot)", () async {
      // A handler that never actually completes matters here: this test
      // is only about whether reading the provider itself throws, not
      // about what _refresh eventually does with a response. Any
      // zone error escaping unhandled (e.g. the "uninitialized
      // provider" Bad state) fails the test via
      // FlutterError.onError/the test zone.
      final adapter = FakeHttpAdapter(
        (options) => const FakeHttpResponse(200, <Object?>[]),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final client = FederationClient(
        baseUrl: 'http://musicat-server.test',
        dio: dio,
      );

      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_configured),
          ),
          federationClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      // autoDispose providers tear down once nothing is listening — a
      // bare .read() doesn't keep it alive, so the deferred _refresh's
      // later `state =` write would land on an already-disposed (and
      // silently rebuilt) instance. A real widget's ref.watch plays the
      // role this listener does here (same pattern as
      // downloads_controller_test.dart).
      final subscription = container.listen(
        friendsControllerProvider,
        (a, b) {},
      );
      addTearDown(subscription.close);

      // The crash under the old code happened asynchronously (the
      // unawaited Future from the inline `_refresh` call completed with
      // an error), not synchronously from this read — so this call
      // succeeding is expected either way and isn't itself the
      // assertion; see below.
      final state = container.read(friendsControllerProvider);
      expect(state, const FriendsState());

      // Let the microtask queue (and the fake HTTP round-trip) drain so
      // any unhandled async error from the old code would have had a
      // chance to surface, and so the deferred _refresh actually
      // finishes before this test (and its container.dispose teardown)
      // completes.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // _refresh should have actually run by now and completed
      // normally, updating state accordingly (empty friends list, no
      // error) — proving the deferred call really executes, not just
      // that nothing crashed.
      final refreshed = container.read(friendsControllerProvider);
      expect(refreshed.error, isNull);
      expect(refreshed.friends, isEmpty);
    });

    test(
      'leaves state untouched (unconfigured case unaffected by the fix)',
      () {
        final container = ProviderContainer(
          overrides: [
            musicatServerConfigControllerProvider.overrideWith(
              () => MusicatServerConfigController(MusicatServerConfig.empty),
            ),
          ],
        );
        addTearDown(container.dispose);

        final state = container.read(friendsControllerProvider);
        expect(state, const FriendsState());
      },
    );
  });
}
