import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/federation/federation_client.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:musicat/features/friends/presentation/friends_screen.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';

import 'fakes/fake_http_adapter.dart';

const _configured = MusicatServerConfig(
  host: 'localhost',
  port: 8080,
  myPublicAddress: 'me.example:8080',
);

/// Stubs out the friends list without going through
/// [FriendsController.build]'s live polling — this test is only concerned
/// with how [FriendsScreen] renders a given [FriendsState], not with
/// [FriendsController]'s own networking/polling behavior.
class _FixedFriendsController extends FriendsController {
  _FixedFriendsController(this._state);

  final FriendsState _state;

  @override
  FriendsState build() => _state;
}

FederationClient _clientWith(
  FakeHttpResponse Function(RequestOptions options) handler,
) {
  final adapter = FakeHttpAdapter(handler);
  final dio = Dio()..httpClientAdapter = adapter;
  return FederationClient(baseUrl: 'http://musicat-server.test', dio: dio);
}

void main() {
  group('_FriendsList relay indicator', () {
    testWidgets('shows a relay icon only for friends with a relayUrl on file', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_configured),
          ),
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(
              const FriendsState(
                friends: [
                  FriendWithStatus(
                    friend: FederationFriend(
                      nodeId: 'friend-with-relay',
                      publicKeyBase64: 'pk1',
                      address: 'a.example:8080',
                      displayName: 'Ada',
                      relayUrl: 'wss://relay.example/session/abc',
                    ),
                    status: FriendConnectionStatus(connected: false),
                  ),
                  FriendWithStatus(
                    friend: FederationFriend(
                      nodeId: 'friend-without-relay',
                      publicKeyBase64: 'pk2',
                      address: 'b.example:8080',
                      displayName: 'Bea',
                    ),
                    status: FriendConnectionStatus(connected: true),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: FriendsScreen()),
        ),
      );
      await tester.pump();

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Bea'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_queue), findsOneWidget);
      expect(find.byTooltip('Has a relay fallback registered'), findsOneWidget);
    });
  });

  group('_ServerConfigSheet relay status row', () {
    testWidgets('shows "Relay: connected" when this node has a relay', (
      tester,
    ) async {
      final client = _clientWith((options) {
        if (options.path == '/api/v1/node') {
          return const FakeHttpResponse(200, {
            'nodeId': 'my-node',
            'publicKeyBase64': 'pk',
            'relayUrl': 'wss://relay.example/session/xyz',
          });
        }
        throw StateError('Unexpected request: ${options.path}');
      });
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_configured),
          ),
          federationClientProvider.overrideWithValue(client),
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(const FriendsState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: FriendsScreen()),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Musicat Server settings'));
      await tester.pumpAndSettle();

      expect(find.text('Relay: connected'), findsOneWidget);
    });

    testWidgets('shows "Relay: not connected" when this node has no relay', (
      tester,
    ) async {
      final client = _clientWith((options) {
        if (options.path == '/api/v1/node') {
          return const FakeHttpResponse(200, {
            'nodeId': 'my-node',
            'publicKeyBase64': 'pk',
          });
        }
        throw StateError('Unexpected request: ${options.path}');
      });
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_configured),
          ),
          federationClientProvider.overrideWithValue(client),
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(const FriendsState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: FriendsScreen()),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Musicat Server settings'));
      await tester.pumpAndSettle();

      expect(find.text('Relay: not connected'), findsOneWidget);
    });
  });
}
