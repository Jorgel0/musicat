import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/audio/audio_providers.dart';
import 'package:musicat/core/invite/invite_uri.dart';
import 'package:musicat/core/invite/pending_invite.dart';
import 'package:musicat/core/network/federation/account_client.dart';
import 'package:musicat/core/routing/app_shell.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:musicat/features/friends/presentation/friends_screen.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_account_client.dart';
import 'fakes/fake_audio_player_controller.dart';
import 'fakes/fake_federation_client.dart';

const _configured = MusicatServerConfig(
  host: 'localhost',
  port: 8080,
  myPublicAddress: 'me.example:8080',
);

final _signedIn = MyAccount(
  accountId: 'acc-1',
  username: 'jorge',
  loggedInAt: DateTime.utc(2026, 9, 5),
);

/// Same rationale as `friends_screen_test.dart`'s own copy: these tests are
/// about what the screen shows, not about `FriendsController`'s polling.
class _FixedFriendsController extends FriendsController {
  _FixedFriendsController(this._state);

  final FriendsState _state;

  @override
  FriendsState build() => _state;
}

IncomingFriendRequest _request({
  String id = 'req-1',
  String? from = 'bob',
  String status = 'pending',
}) => IncomingFriendRequest(id: id, fromUsername: from, status: status);

ProviderContainer _containerWith(FakeAccountClient client) {
  final container = ProviderContainer(
    overrides: [
      musicatServerConfigControllerProvider.overrideWith(
        () => MusicatServerConfigController(_configured),
      ),
      federationClientProvider.overrideWithValue(FakeFederationClient()),
      accountClientProvider.overrideWithValue(client),
      friendsControllerProvider.overrideWith(
        () => _FixedFriendsController(const FriendsState()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpFriendsScreen(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FriendsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('incoming friend requests', () {
    testWidgets('a waiting request is on the Friends screen itself, with '
        'both answers one tap away', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: [_request()],
          fetchedAt: DateTime.utc(2026, 9, 5),
          live: true,
        ),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('1 friend request'), findsOneWidget);
      expect(find.text('bob wants to be your friend'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Decline'), findsOneWidget);
    });

    testWidgets('accepting answers it and reports the friendship, not the '
        'request record', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: [_request()],
          fetchedAt: DateTime.utc(2026, 9, 5),
          live: true,
        ),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
      await tester.pumpAndSettle();

      expect(client.respondCalls, [(id: 'req-1', accept: true)]);
      expect(find.text('You and bob are now friends.'), findsOneWidget);
      // Answered, so it is gone from the screen.
      expect(find.text('bob wants to be your friend'), findsNothing);
    });

    testWidgets('declining answers it and never claims a friendship', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: [_request()],
          fetchedAt: DateTime.utc(2026, 9, 5),
          live: true,
        ),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.widgetWithText(TextButton, 'Decline'));
      await tester.pumpAndSettle();

      expect(client.respondCalls, [(id: 'req-1', accept: false)]);
      expect(find.text('Declined the request from bob.'), findsOneWidget);
      expect(find.textContaining('are now friends'), findsNothing);
    });

    testWidgets('a request that was already answered elsewhere says exactly '
        'that instead of failing silently', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: [_request()],
          fetchedAt: DateTime.utc(2026, 9, 5),
          live: true,
        ),
      )..respondError = const AccountClientException(409, 'already answered');

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
      await tester.pumpAndSettle();

      expect(
        find.text('That request had already been answered.'),
        findsOneWidget,
      );
    });

    testWidgets('several waiting requests are all listed, and counted', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: [
            _request(id: 'req-1', from: 'bob'),
            _request(id: 'req-2', from: 'ada'),
          ],
          fetchedAt: DateTime.utc(2026, 9, 5),
          live: true,
        ),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('2 friend requests'), findsOneWidget);
      expect(find.text('bob wants to be your friend'), findsOneWidget);
      expect(find.text('ada wants to be your friend'), findsOneWidget);
    });

    testWidgets('an already-accepted entry is not offered for answering '
        'again', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: [_request(id: 'req-1', from: 'bob', status: 'accepted')],
          fetchedAt: DateTime.utc(2026, 9, 5),
          live: true,
        ),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.textContaining('wants to be your friend'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);
    });
  });

  group('honesty about what this device actually knows', () {
    testWidgets('an empty list it has never managed to fetch is never shown '
        'as "no requests"', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        // Exactly the contract's `live: false, fetchedAt: null`.
        requests: const FriendRequestsSnapshot(requests: [], live: false),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(
        find.text(
          'Could not check for friend requests yet — there may be some '
          'waiting.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('no friend requests'), findsNothing);
      expect(find.textContaining('No friend requests'), findsNothing);
    });

    testWidgets('a stale empty snapshot says what it last saw, and when it '
        'last saw it', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: const [],
          fetchedAt: DateTime.utc(2026, 9, 5, 9),
          live: false,
        ),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(
        find.text(
          'Could not check for friend requests just now. Last time this '
          'device checked, there were none.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a stale snapshot that does hold requests still shows them, '
        'flagged as possibly out of date', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: [_request()],
          fetchedAt: DateTime.utc(2026, 9, 5, 9),
          live: false,
        ),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('bob wants to be your friend'), findsOneWidget);
      expect(
        find.textContaining('this is what this device last saw'),
        findsOneWidget,
      );
    });

    testWidgets('a fresh, genuinely empty answer takes up no space at all', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: FriendRequestsSnapshot(
          requests: const [],
          fetchedAt: DateTime.utc(2026, 9, 5),
          live: true,
        ),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.textContaining('friend request'), findsNothing);
      expect(find.textContaining('Could not check'), findsNothing);
    });

    testWidgets('a failed check admits it and offers to try again', (
      tester,
    ) async {
      final client = FakeAccountClient(account: _signedIn)
        ..listError = const AccountClientException(0, 'connection refused');

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(
        find.textContaining('Could not check for friend requests just now'),
        findsOneWidget,
      );
      final callsBefore = client.listCalls;

      await tester.tap(find.widgetWithText(TextButton, 'Check again'));
      await tester.pumpAndSettle();

      expect(client.listCalls, greaterThan(callsBefore));
    });

    testWidgets('a signed-out device is not told anything about friend '
        'requests, and is not asked to check', (tester) async {
      final client = FakeAccountClient();

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.textContaining('friend request'), findsNothing);
      expect(find.textContaining('Could not check'), findsNothing);
      expect(client.listCalls, 0);
    });
  });

  group('the account strip on the Friends screen', () {
    testWidgets('shows the username this device is signed in as', (
      tester,
    ) async {
      final client = FakeAccountClient(account: _signedIn);

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('Signed in as jorge'), findsOneWidget);
    });

    testWidgets('offers signing in, without hiding anything, when signed '
        'out', (tester) async {
      final client = FakeAccountClient();

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('Add friends by username'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
      // The pre-accounts way in is untouched: the add-friend button is
      // right where it was.
      expect(find.byIcon(Icons.person_add_alt), findsOneWidget);
    });
  });

  group('adding a friend by username', () {
    testWidgets('is one field and one button, and closes the sheet', (
      tester,
    ) async {
      final client = FakeAccountClient(account: _signedIn);

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, "Friend's username"),
        'bob',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send request'));
      await tester.pumpAndSettle();

      expect(client.sentRequests, ['bob']);
      expect(find.textContaining('Friend request sent to bob'), findsOneWidget);
      // Sheet closed: nothing left to do.
      expect(find.widgetWithText(FilledButton, 'Send request'), findsNothing);
    });

    testWidgets('a username nobody is using says so, and keeps the sheet '
        'open to fix it', (tester) async {
      final client = FakeAccountClient(account: _signedIn)
        ..sendError = const AccountClientException(404, 'Unknown username');

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, "Friend's username"),
        'ghost',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send request'));
      await tester.pumpAndSettle();

      expect(
        find.text('No one is using the username "ghost".'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Send request'), findsOneWidget);
    });

    testWidgets('requests being unavailable never reads as a bad username', (
      tester,
    ) async {
      final client = FakeAccountClient(account: _signedIn)
        ..sendError = const AccountClientException(503, 'unreachable');

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, "Friend's username"),
        'bob',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send request'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Friend requests are not available right now'),
        findsOneWidget,
      );
      expect(find.textContaining('No one is using'), findsNothing);
    });

    testWidgets('an empty username is refused locally, with no request sent', (
      tester,
    ) async {
      final client = FakeAccountClient(account: _signedIn);

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send request'));
      await tester.pumpAndSettle();

      expect(find.text('Enter their username.'), findsOneWidget);
      expect(client.sentRequests, isEmpty);
    });
  });

  group('the invite-code way survives, folded away', () {
    testWidgets('signed in, it is offered but not in the way — and opens on '
        'demand (ADR 0038/0045 is a standing decision, not clutter)', (
      tester,
    ) async {
      final client = FakeAccountClient(account: _signedIn);

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();

      expect(find.text('Add with an invite code instead'), findsOneWidget);
      // Folded away, so the one-field path is what the sheet is about.
      expect(find.text('Your invite'), findsNothing);
      expect(find.widgetWithText(TextField, "Friend's address"), findsNothing);

      await tester.tap(find.text('Add with an invite code instead'));
      await tester.pumpAndSettle();

      expect(find.text('Your invite'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, "Friend's address"),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Add friend'), findsOneWidget);
    });

    testWidgets('opens by itself when the sheet was opened by an invite '
        'link, so a deep link never lands on a folded-away form', (
      tester,
    ) async {
      final client = FakeAccountClient(account: _signedIn);
      final container = _containerWith(client);
      container
          .read(pendingInviteProvider.notifier)
          .set(
            const PendingFriendInvite(
              FriendInvite(address: 'deep-link.example:8080', code: 'deep'),
            ),
          );

      await _pumpFriendsScreen(tester, container);

      final addressField = tester.widget<TextField>(
        find.widgetWithText(TextField, "Friend's address"),
      );
      expect(addressField.controller!.text, 'deep-link.example:8080');
    });

    testWidgets('signed out, it is the whole sheet exactly as before — '
        'accounts add a way in, they do not take one away', (tester) async {
      final client = FakeAccountClient();

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.byIcon(Icons.person_add_alt));
      await tester.pumpAndSettle();

      expect(find.text('Your invite'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, "Friend's address"),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, "Friend's code"), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add friend'), findsOneWidget);
      // With an offer to make it simpler next time, and no username field
      // pretending to work without an account.
      expect(
        find.widgetWithText(OutlinedButton, 'Sign in or create an account'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Send request'), findsNothing);
    });
  });

  group('the Friends tab badge', () {
    Future<void> pumpShell(
      WidgetTester tester,
      FakeAccountClient client,
    ) async {
      final container = ProviderContainer(
        overrides: [
          musicatServerConfigControllerProvider.overrideWith(
            () => MusicatServerConfigController(_configured),
          ),
          federationClientProvider.overrideWithValue(FakeFederationClient()),
          accountClientProvider.overrideWithValue(client),
          audioPlayerControllerProvider.overrideWithValue(
            FakeAudioPlayerController(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: AppShell(location: '/', child: SizedBox()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('counts waiting requests from anywhere in the app — the '
        'point being that they are impossible to miss', (tester) async {
      await pumpShell(
        tester,
        FakeAccountClient(
          account: _signedIn,
          requests: FriendRequestsSnapshot(
            requests: [
              _request(id: 'req-1', from: 'bob'),
              _request(id: 'req-2', from: 'ada'),
            ],
            fetchedAt: DateTime.utc(2026, 9, 5),
            live: true,
          ),
        ),
      );

      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('claims nothing when there is nothing waiting', (tester) async {
      await pumpShell(
        tester,
        FakeAccountClient(
          account: _signedIn,
          requests: FriendRequestsSnapshot(
            requests: const [],
            fetchedAt: DateTime.utc(2026, 9, 5),
            live: true,
          ),
        ),
      );

      expect(find.text('0'), findsNothing);
    });

    testWidgets('claims nothing when this device could not check', (
      tester,
    ) async {
      await pumpShell(
        tester,
        FakeAccountClient(account: _signedIn)
          ..listError = const AccountClientException(0, 'refused'),
      );

      expect(find.text('0'), findsNothing);
      expect(find.text('1'), findsNothing);
    });
  });
}
