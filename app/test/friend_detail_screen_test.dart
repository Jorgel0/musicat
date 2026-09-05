import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/federation/federation_client.dart';
import 'package:musicat/features/friends/presentation/friend_detail_screen.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';

import 'fakes/fake_federation_client.dart';

/// Stubs out the friends list without going through
/// [FriendsController.build]'s live polling — same rationale/pattern as
/// `friends_screen_test.dart`'s own `_FixedFriendsController`. Methods
/// other than `build` (e.g. `setLocalNickname`) are inherited unchanged,
/// so they still run for real against whatever [FederationClient] is
/// injected via [federationClientProvider].
class _FixedFriendsController extends FriendsController {
  _FixedFriendsController(this._state);

  final FriendsState _state;

  @override
  FriendsState build() => _state;
}

void main() {
  group('FriendDetailScreen title', () {
    testWidgets('shows displayName when no localNickname is set', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(
              const FriendsState(
                friends: [
                  FriendWithStatus(
                    friend: FederationFriend(
                      nodeId: 'n1',
                      publicKeyBase64: 'pk1',
                      address: 'a.example:8080',
                      displayName: 'Ada',
                    ),
                  ),
                ],
              ),
            ),
          ),
          sharingClientProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: FriendDetailScreen(nodeId: 'n1')),
        ),
      );
      await tester.pump();

      expect(find.widgetWithText(AppBar, 'Ada'), findsOneWidget);
    });

    testWidgets('shows the raw nodeId when neither name is set', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(
              const FriendsState(
                friends: [
                  FriendWithStatus(
                    friend: FederationFriend(
                      nodeId: 'raw-node-id',
                      publicKeyBase64: 'pk1',
                      address: 'a.example:8080',
                    ),
                  ),
                ],
              ),
            ),
          ),
          sharingClientProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: FriendDetailScreen(nodeId: 'raw-node-id'),
          ),
        ),
      );
      await tester.pump();

      expect(find.widgetWithText(AppBar, 'raw-node-id'), findsOneWidget);
    });
  });

  group('FriendDetailScreen nickname editing', () {
    testWidgets(
      'entering a nickname sends it via the client and updates the title '
      '(regression coverage for the localNickname/displayName precedence)',
      (tester) async {
        final client = FakeFederationClient(
          friends: const [
            FederationFriend(
              nodeId: 'n1',
              publicKeyBase64: 'pk1',
              address: 'a.example:8080',
              displayName: 'Ada',
            ),
          ],
        );
        final container = ProviderContainer(
          overrides: [
            federationClientProvider.overrideWithValue(client),
            friendsControllerProvider.overrideWith(
              () => _FixedFriendsController(
                FriendsState(friends: client.friends.map(_withStatus).toList()),
              ),
            ),
            sharingClientProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: FriendDetailScreen(nodeId: 'n1')),
          ),
        );
        await tester.pump();

        expect(find.widgetWithText(AppBar, 'Ada'), findsOneWidget);

        await tester.tap(find.byTooltip('Edit nickname'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Nickname'),
          'My nickname for Ada',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(client.setLocalNicknameCalls, [
          (nodeId: 'n1', nickname: 'My nickname for Ada'),
        ]);
        expect(
          find.widgetWithText(AppBar, 'My nickname for Ada'),
          findsOneWidget,
        );
        expect(find.widgetWithText(AppBar, 'Ada'), findsNothing);
      },
    );

    testWidgets(
      'submitting an empty nickname clears it, reverting the title to '
      'displayName',
      (tester) async {
        final client = FakeFederationClient(
          friends: const [
            FederationFriend(
              nodeId: 'n1',
              publicKeyBase64: 'pk1',
              address: 'a.example:8080',
              displayName: 'Ada',
              localNickname: 'Old nickname',
            ),
          ],
        );
        final container = ProviderContainer(
          overrides: [
            federationClientProvider.overrideWithValue(client),
            friendsControllerProvider.overrideWith(
              () => _FixedFriendsController(
                FriendsState(friends: client.friends.map(_withStatus).toList()),
              ),
            ),
            sharingClientProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: FriendDetailScreen(nodeId: 'n1')),
          ),
        );
        await tester.pump();

        expect(find.widgetWithText(AppBar, 'Old nickname'), findsOneWidget);

        await tester.tap(find.byTooltip('Edit nickname'));
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextField, 'Nickname'), '');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(client.setLocalNicknameCalls, [(nodeId: 'n1', nickname: null)]);
        expect(find.widgetWithText(AppBar, 'Ada'), findsOneWidget);
      },
    );

    testWidgets('cancelling the dialog sends nothing and leaves the title '
        'unchanged', (tester) async {
      final client = FakeFederationClient(
        friends: const [
          FederationFriend(
            nodeId: 'n1',
            publicKeyBase64: 'pk1',
            address: 'a.example:8080',
            displayName: 'Ada',
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          federationClientProvider.overrideWithValue(client),
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(
              FriendsState(friends: client.friends.map(_withStatus).toList()),
            ),
          ),
          sharingClientProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: FriendDetailScreen(nodeId: 'n1')),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Edit nickname'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Nickname'),
        'Should not be saved',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(client.setLocalNicknameCalls, isEmpty);
      expect(find.widgetWithText(AppBar, 'Ada'), findsOneWidget);
    });
  });

  group('a friend with several devices', () {
    /// Mounts the screen for [friend] with no shared tracks, which is all
    /// the device summary needs — same shape as the nickname tests above.
    Future<void> pumpFor(WidgetTester tester, FederationFriend friend) async {
      final container = ProviderContainer(
        overrides: [
          friendsControllerProvider.overrideWith(
            () => _FixedFriendsController(
              FriendsState(friends: [_withStatus(friend)]),
            ),
          ),
          sharingClientProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: FriendDetailScreen(nodeId: friend.nodeId)),
        ),
      );
      await tester.pump();
    }

    testWidgets('says how many devices they use, and something useful about '
        'each — without ever showing a node id', (tester) async {
      final now = DateTime.now();
      await pumpFor(
        tester,
        FederationFriend(
          nodeId: 'device-1',
          publicKeyBase64: 'pk1',
          address: 'a.example:8080',
          displayName: 'Ada',
          accountId: 'acc-ada',
          devices: [
            FriendDevice(
              nodeId: 'device-1',
              address: 'a.example:8080',
              linkedAt: now.subtract(const Duration(days: 3)),
            ),
            FriendDevice(
              nodeId: 'device-2',
              relayUrl: 'wss://relay.example/session/xyz',
              linkedAt: now.subtract(const Duration(days: 1)),
            ),
          ],
        ),
      );

      expect(find.text('Uses Musicat on 2 devices'), findsOneWidget);
      expect(find.text('Added 3 days ago · reachable'), findsOneWidget);
      expect(find.text('Added yesterday · reachable'), findsOneWidget);
      // The plumbing stays out of the copy.
      expect(find.textContaining('device-1'), findsNothing);
      expect(find.textContaining('device-2'), findsNothing);
      expect(find.textContaining('wss://'), findsNothing);
    });

    testWidgets('a device with nowhere to reach it says so rather than '
        'implying it works', (tester) async {
      await pumpFor(
        tester,
        FederationFriend(
          nodeId: 'device-1',
          publicKeyBase64: 'pk1',
          address: 'a.example:8080',
          displayName: 'Ada',
          accountId: 'acc-ada',
          devices: [
            const FriendDevice(nodeId: 'device-1', address: 'a.example:8080'),
            const FriendDevice(nodeId: 'device-2'),
          ],
        ),
      );

      expect(
        find.text('Added a while ago · no way to reach it yet'),
        findsOneWidget,
      );
    });

    testWidgets('an ordinary one-device friend gets no device section at '
        'all', (tester) async {
      await pumpFor(
        tester,
        const FederationFriend(
          nodeId: 'device-1',
          publicKeyBase64: 'pk1',
          address: 'a.example:8080',
          displayName: 'Ada',
          devices: [FriendDevice(nodeId: 'device-1')],
        ),
      );

      expect(find.textContaining('Uses Musicat on'), findsNothing);
    });
  });
}

FriendWithStatus _withStatus(FederationFriend friend) =>
    FriendWithStatus(friend: friend);
