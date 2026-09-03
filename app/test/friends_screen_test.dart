import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/embedded_server/embedded_server.dart';
import 'package:musicat/core/invite/invite_uri.dart';
import 'package:musicat/core/invite/pending_invite.dart';
import 'package:musicat/core/network/federation/federation_client.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:musicat/features/friends/presentation/friends_screen.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_federation_client.dart';
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
  // `_ServerConfigSheet`'s "Save" button persists via
  // `MusicatServerConfigController.save`, which reads/writes real
  // `SharedPreferences` — mocked here so any test that actually taps
  // "Save" doesn't hit a missing platform channel.
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  group('_FriendsList name precedence', () {
    testWidgets(
      'prefers localNickname, then displayName, then the raw nodeId',
      (tester) async {
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
                        nodeId: 'has-both',
                        publicKeyBase64: 'pk1',
                        address: 'a.example:8080',
                        displayName: "Their own name",
                        localNickname: 'My nickname for them',
                      ),
                    ),
                    FriendWithStatus(
                      friend: FederationFriend(
                        nodeId: 'has-display-name-only',
                        publicKeyBase64: 'pk2',
                        address: 'b.example:8080',
                        displayName: 'Bea',
                      ),
                    ),
                    FriendWithStatus(
                      friend: FederationFriend(
                        nodeId: 'raw-node-id',
                        publicKeyBase64: 'pk3',
                        address: 'c.example:8080',
                      ),
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

        expect(find.text('My nickname for them'), findsOneWidget);
        expect(find.text("Their own name"), findsNothing);
        expect(find.text('Bea'), findsOneWidget);
        expect(find.text('raw-node-id'), findsOneWidget);
      },
    );
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

  group('_ServerConfigSheet "Relay URL (optional)" field', () {
    testWidgets('is shown when using the built-in server, with hint text about '
        'cross-network reachability and needing a restart to take effect', (
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
            () => MusicatServerConfigController(
              const MusicatServerConfig(
                host: '',
                port: 8080,
                myPublicAddress: 'me.example:8080',
                useEmbeddedServer: true,
              ),
            ),
          ),
          federationClientProvider.overrideWithValue(client),
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(const FriendsState()),
          ),
          embeddedServerProvider.overrideWith(
            (ref) async => const EmbeddedServerInfo(port: 12345),
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

      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Relay URL (optional)'),
      );
      expect(field.decoration?.hintText, contains('different network'));
      expect(field.decoration?.hintText, contains('restart'));
    });

    testWidgets('is hidden when not using the built-in server (a manually '
        'self-hosted server sets its own relay independently, through its '
        'own environment, not through this app)', (tester) async {
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

      expect(
        find.widgetWithText(TextField, 'Relay URL (optional)'),
        findsNothing,
      );
    });

    testWidgets('pre-fills from the current config, and saving persists it', (
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
            () => MusicatServerConfigController(
              const MusicatServerConfig(
                host: '',
                port: 8080,
                myPublicAddress: 'me.example:8080',
                useEmbeddedServer: true,
                relayUrl: 'wss://old-relay.example/connect',
              ),
            ),
          ),
          federationClientProvider.overrideWithValue(client),
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(const FriendsState()),
          ),
          embeddedServerProvider.overrideWith(
            (ref) async => const EmbeddedServerInfo(port: 12345),
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

      final relayField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Relay URL (optional)'),
      );
      expect(relayField.controller!.text, 'wss://old-relay.example/connect');

      await tester.enterText(
        find.widgetWithText(TextField, 'Relay URL (optional)'),
        'wss://new-relay.example/connect',
      );
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        container.read(musicatServerConfigControllerProvider).relayUrl,
        'wss://new-relay.example/connect',
      );
    });

    testWidgets('saving an empty relay URL clears it (stores null)', (
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
            () => MusicatServerConfigController(
              const MusicatServerConfig(
                host: '',
                port: 8080,
                myPublicAddress: 'me.example:8080',
                useEmbeddedServer: true,
                relayUrl: 'wss://old-relay.example/connect',
              ),
            ),
          ),
          federationClientProvider.overrideWithValue(client),
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(const FriendsState()),
          ),
          embeddedServerProvider.overrideWith(
            (ref) async => const EmbeddedServerInfo(port: 12345),
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

      await tester.enterText(
        find.widgetWithText(TextField, 'Relay URL (optional)'),
        '',
      );
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        container.read(musicatServerConfigControllerProvider).relayUrl,
        isNull,
      );
    });
  });

  group('_ServerConfigSheet "Your display name" field', () {
    testWidgets('pre-fills from the current config, and saving persists it', (
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
            () => MusicatServerConfigController(
              const MusicatServerConfig(
                host: 'localhost',
                port: 8080,
                myPublicAddress: 'me.example:8080',
                myDisplayName: 'Old Name',
              ),
            ),
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

      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Your display name'),
      );
      expect(nameField.controller!.text, 'Old Name');

      await tester.enterText(
        find.widgetWithText(TextField, 'Your display name'),
        'New Name',
      );
      // The "Use the built-in server" toggle (only relevant on
      // Linux/Windows, which is what this test suite runs on) pushed
      // "Save" below the default test viewport — scroll it into view
      // before tapping, same as a real short window/screen would need.
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        container.read(musicatServerConfigControllerProvider).myDisplayName,
        'New Name',
      );
    });

    testWidgets('saving an empty display name clears it (stores null)', (
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
            () => MusicatServerConfigController(
              const MusicatServerConfig(
                host: 'localhost',
                port: 8080,
                myPublicAddress: 'me.example:8080',
                myDisplayName: 'Old Name',
              ),
            ),
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

      await tester.enterText(
        find.widgetWithText(TextField, 'Your display name'),
        '',
      );
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        container.read(musicatServerConfigControllerProvider).myDisplayName,
        isNull,
      );
    });
  });

  group('_AddFriendSheet "paste an invite link" fallback', () {
    testWidgets(
      'a pasted friend-invite link pre-fills address/code, no auto-submit, '
      'and no longer shows a "Name (optional)" field (that field used to '
      'be sent as this device\'s own displayName, crossing names with the '
      'friend being added — see MusicatServerConfig.myDisplayName instead)',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            musicatServerConfigControllerProvider.overrideWith(
              () => MusicatServerConfigController(_configured),
            ),
            // The sheet now also watches myNodeInfoProvider itself (to
            // decide whether to show its "By username" add-friend mode) —
            // a fake here keeps that off the real network, same reason
            // the sibling tests below need it too.
            federationClientProvider.overrideWithValue(FakeFederationClient()),
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

        // The invite carried a `name` (Casey), but the add-friend flow has
        // no field for it any more — it would only ever have been sent as
        // *this device's own* displayName, not a label for the friend.
        expect(find.widgetWithText(TextField, 'Name (optional)'), findsNothing);

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
            federationClientProvider.overrideWithValue(FakeFederationClient()),
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
          federationClientProvider.overrideWithValue(FakeFederationClient()),
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

    testWidgets(
      'pasting a link with malformed percent-encoding shows a friendly '
      'error instead of crashing (regression: Uri.queryParameters used to '
      'throw a raw FormatException that escaped the on InviteUriException '
      'catch here)',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            musicatServerConfigControllerProvider.overrideWith(
              () => MusicatServerConfigController(_configured),
            ),
            federationClientProvider.overrideWithValue(FakeFederationClient()),
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
          'musicat://friend?address=%e0%e0&code=abc',
        );
        await tester.tap(find.widgetWithText(OutlinedButton, 'Use'));
        await tester.pump();

        expect(find.text('This invite link is malformed.'), findsOneWidget);
      },
    );
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
            federationClientProvider.overrideWithValue(FakeFederationClient()),
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
        // The sheet also watches myNodeInfoProvider (to decide whether to
        // show its "By username" add-friend mode) — served here as "no
        // relay connected" so this test doesn't need to care about it.
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

  group('_ServerConfigSheet "Choose your username"', () {
    testWidgets(
      'is hidden (with an explanatory note) when this device has no relay '
      'connected',
      (tester) async {
        final client = FakeFederationClient(
          myNode: const MyNodeInfo(nodeId: 'my-node', publicKeyBase64: 'pk'),
        );
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

        expect(
          find.text('Connect to a relay to claim a username.'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextField, 'Your username (optional)'),
          findsNothing,
        );
      },
    );

    testWidgets('claiming a username succeeds and shows a success snackbar', (
      tester,
    ) async {
      final client = FakeFederationClient(
        myNode: const MyNodeInfo(
          nodeId: 'my-node',
          publicKeyBase64: 'pk',
          relayUrl: 'wss://relay.example:9443/session/abc',
        ),
      );
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

      await tester.enterText(
        find.widgetWithText(TextField, 'Your username (optional)'),
        'coolname',
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Claim'));
      await tester.pumpAndSettle();

      expect(client.setUsernameCalls, ['coolname']);
      expect(find.text('Username "coolname" claimed.'), findsOneWidget);
    });

    testWidgets(
      'claiming an already-taken username shows a clear message, not a '
      'generic error',
      (tester) async {
        final client =
            FakeFederationClient(
                myNode: const MyNodeInfo(
                  nodeId: 'my-node',
                  publicKeyBase64: 'pk',
                  relayUrl: 'wss://relay.example:9443/session/abc',
                ),
              )
              ..setUsernameError = const FederationClientException(
                409,
                'Username already taken',
              );
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

        await tester.enterText(
          find.widgetWithText(TextField, 'Your username (optional)'),
          'taken',
        );
        await tester.tap(find.widgetWithText(OutlinedButton, 'Claim'));
        await tester.pumpAndSettle();

        expect(
          find.text('That username is already taken — try another one.'),
          findsOneWidget,
        );
        // Not the raw exception text, and not a generic fallback message.
        expect(find.text('Username already taken'), findsNothing);
      },
    );
  });

  group('_AddFriendSheet "By username" mode', () {
    testWidgets('the "By address"/"By username" toggle is hidden, and only the '
        'address field is shown, when this device has no relay connected', (
      tester,
    ) async {
      final client = FakeFederationClient(
        myNode: const MyNodeInfo(nodeId: 'my-node', publicKeyBase64: 'pk'),
      );
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

      expect(find.text('By address'), findsNothing);
      expect(find.text('By username'), findsNothing);
      expect(
        find.widgetWithText(TextField, "Friend's address"),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, "Friend's username"), findsNothing);
    });

    testWidgets('resolves a username via this device\'s own relay, then calls '
        'addFriend with the relay-routed address', (tester) async {
      final client = FakeFederationClient(
        myNode: const MyNodeInfo(
          nodeId: 'my-node',
          publicKeyBase64: 'pk',
          relayUrl: 'wss://relay.example:9443/session/abc',
        ),
      )..usernameDirectory['bob'] = 'node-bob';
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

      await tester.tap(find.text('By username'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, "Friend's username"),
        'bob',
      );
      await tester.enterText(
        find.widgetWithText(TextField, "Friend's code"),
        'the-code',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Add friend'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add friend'));
      await tester.pumpAndSettle();

      expect(client.lookupUsernameCalls, ['bob']);
      expect(client.addFriendCalls, hasLength(1));
      final call = client.addFriendCalls.single;
      expect(call.friendBaseUrl, 'http://relay.example:9443/node-bob');
      expect(call.code, 'the-code');
    });

    testWidgets(
      'a failed username lookup (not found) shows a clear error and never '
      'calls addFriend',
      (tester) async {
        final client = FakeFederationClient(
          myNode: const MyNodeInfo(
            nodeId: 'my-node',
            publicKeyBase64: 'pk',
            relayUrl: 'wss://relay.example:9443/session/abc',
          ),
        );
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

        await tester.tap(find.text('By username'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, "Friend's username"),
          'ghost',
        );
        await tester.enterText(
          find.widgetWithText(TextField, "Friend's code"),
          'the-code',
        );
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Add friend'),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Add friend'));
        await tester.pumpAndSettle();

        expect(find.text('Username not found'), findsOneWidget);
        expect(client.addFriendCalls, isEmpty);
      },
    );

    testWidgets(
      'a failed username lookup (no relay currently connected) shows a '
      'clear error and never calls addFriend',
      (tester) async {
        final client =
            FakeFederationClient(
                myNode: const MyNodeInfo(
                  nodeId: 'my-node',
                  publicKeyBase64: 'pk',
                  relayUrl: 'wss://relay.example:9443/session/abc',
                ),
              )
              ..lookupUsernameError = const FederationClientException(
                503,
                'No relay is currently connected to this node',
              );
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

        await tester.tap(find.text('By username'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, "Friend's username"),
          'bob',
        );
        await tester.enterText(
          find.widgetWithText(TextField, "Friend's code"),
          'the-code',
        );
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Add friend'),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Add friend'));
        await tester.pumpAndSettle();

        expect(
          find.text('No relay is currently connected to this node'),
          findsOneWidget,
        );
        expect(client.addFriendCalls, isEmpty);
      },
    );
  });
}
