import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/invite/invite_uri.dart';
import 'package:musicat/core/invite/pending_invite.dart';
import 'package:musicat/core/network/federation/federation_client.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:musicat/features/friends/presentation/friends_screen.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';
import 'package:qr_flutter/qr_flutter.dart';

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

  group('_AddFriendSheet "paste an invite link" fallback', () {
    testWidgets(
      'a pasted friend-invite link pre-fills address/code/name, no auto-submit',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            musicatServerConfigControllerProvider.overrideWith(
              () => MusicatServerConfigController(_configured),
            ),
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
        await tester.tap(find.byIcon(Icons.person_add_alt));
        await tester.pumpAndSettle();

        const invite = FriendInvite(
          address: 'pasted.example:9090',
          code: 'paste-code',
          displayName: 'Casey',
        );
        final raw = InviteUri.build(invite).toString();

        await tester.enterText(
          find.widgetWithText(TextField, 'Or paste an invite link'),
          raw,
        );
        await tester.tap(find.widgetWithText(OutlinedButton, 'Use'));
        await tester.pump();

        expect(
          find.widgetWithText(TextField, "Friend's address"),
          findsOneWidget,
        );
        final addressField = tester.widget<TextField>(
          find.widgetWithText(TextField, "Friend's address"),
        );
        expect(addressField.controller!.text, 'pasted.example:9090');

        final codeField = tester.widget<TextField>(
          find.widgetWithText(TextField, "Friend's code"),
        );
        expect(codeField.controller!.text, 'paste-code');

        final nameField = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Name (optional)'),
        );
        expect(nameField.controller!.text, 'Casey');

        // Never auto-submits — the sheet is still open, "Add friend" was
        // never tapped.
        expect(find.text('Add friend'), findsOneWidget);
      },
    );

    testWidgets(
      'pasting a playlist invite (not a friend invite) shows an error, '
      'does not touch the fields',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            musicatServerConfigControllerProvider.overrideWith(
              () => MusicatServerConfigController(_configured),
            ),
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
        await tester.tap(find.byIcon(Icons.person_add_alt));
        await tester.pumpAndSettle();

        final raw = InviteUri.build(
          const PlaylistInvite(id: 'some-playlist'),
        ).toString();

        await tester.enterText(
          find.widgetWithText(TextField, 'Or paste an invite link'),
          raw,
        );
        await tester.tap(find.widgetWithText(OutlinedButton, 'Use'));
        await tester.pump();

        expect(find.text('That link is not a friend invite.'), findsOneWidget);
      },
    );

    testWidgets('pasting garbage text shows a clear parse error', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_configured),
          ),
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
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Or paste an invite link'),
        'not a link',
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Use'));
      await tester.pump();

      expect(find.text('Not a "musicat://" link.'), findsOneWidget);
    });
  });

  group('_AddFriendSheet deep-link pre-fill', () {
    testWidgets(
      'a pending friend invite auto-opens the Add Friend sheet, pre-filled',
      (tester) async {
        const invite = FriendInvite(
          address: 'deep-link.example:8080',
          code: 'deep-code',
        );
        final container = ProviderContainer(
          overrides: [
            musicatServerConfigControllerProvider.overrideWith(
              () => MusicatServerConfigController(_configured),
            ),
            friendsControllerProvider.overrideWith(
              () => _FixedFriendsController(const FriendsState()),
            ),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(pendingInviteProvider.notifier)
            .set(const PendingFriendInvite(invite));

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: FriendsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Sheet opened on its own, no tap needed.
        expect(find.text('Add a friend'), findsOneWidget);
        final addressField = tester.widget<TextField>(
          find.widgetWithText(TextField, "Friend's address"),
        );
        expect(addressField.controller!.text, 'deep-link.example:8080');

        // Consumed — a rebuild doesn't reopen it a second time.
        expect(container.read(pendingInviteProvider), isNull);
      },
    );
  });

  group('_AddFriendSheet "Your invite" QR code', () {
    testWidgets('renders a QR code encoding the friend-invite link once a '
        'code is generated', (tester) async {
      final client = _clientWith((options) {
        if (options.path == '/api/v1/federation/pairing-codes') {
          return const FakeHttpResponse(200, {'code': 'qr-code-value'});
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
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Generate a code'));
      await tester.pumpAndSettle();

      final expectedUri = InviteUri.build(
        const FriendInvite(address: 'me.example:8080', code: 'qr-code-value'),
      ).toString();

      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.byKey(ValueKey('friend-invite-qr:$expectedUri')),
        findsOneWidget,
      );
    });
  });
}
