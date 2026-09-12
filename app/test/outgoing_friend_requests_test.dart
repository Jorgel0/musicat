import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/network/federation/account_client.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/friends_controller.dart';
import 'package:musicat/features/friends/presentation/friends_screen.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_account_client.dart';
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

/// Same rationale as `friend_requests_test.dart`'s own copy: these tests
/// are about what the screen shows, not about `FriendsController`'s polling.
class _FixedFriendsController extends FriendsController {
  _FixedFriendsController(this._state);

  final FriendsState _state;

  @override
  FriendsState build() => _state;
}

OutgoingFriendRequest _sent({
  String id = 'req-1',
  String? to = 'bob',
  String status = 'pending',
  int daysAgo = 3,
}) => OutgoingFriendRequest(
  id: id,
  toUsername: to,
  status: status,
  sentAt: DateTime.now().subtract(Duration(days: daysAgo)),
);

FriendRequestsSnapshot _snapshotWith(
  List<OutgoingFriendRequest> outgoing, {
  List<IncomingFriendRequest> incoming = const [],
  bool live = true,
}) => FriendRequestsSnapshot(
  requests: incoming,
  outgoing: outgoing,
  fetchedAt: DateTime.utc(2026, 9, 5),
  live: live,
);

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

Future<void> _cancelRequest(
  WidgetTester tester, {
  required String confirm,
}) async {
  await tester.tap(find.widgetWithText(TextButton, 'Cancel request'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.widgetWithText(
      confirm == 'Take it back' ? FilledButton : TextButton,
      confirm,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a request you sent no longer vanishes', () {
    testWidgets('it is on the Friends screen, named, with how long they have '
        'had it', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith([_sent()]),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('Waiting for an answer'), findsOneWidget);
      expect(find.text('bob has not answered yet'), findsOneWidget);
      expect(find.text('Sent 3 days ago'), findsOneWidget);
      // There is something to do about it, and it is not "remove bob".
      expect(find.widgetWithText(TextButton, 'Cancel request'), findsOneWidget);
    });

    testWidgets('sending one puts it there straight away, rather than into '
        'nothing at all', (tester) async {
      final client = FakeAccountClient(account: _signedIn);

      await _pumpFriendsScreen(tester, _containerWith(client));
      expect(find.text('Waiting for an answer'), findsNothing);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, "Friend's username"),
        'bob',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send request'));
      await tester.pumpAndSettle();

      expect(client.sentRequests, ['bob']);
      expect(find.text('bob has not answered yet'), findsOneWidget);
    });

    testWidgets('a request the service could not name a recipient for is not '
        'given an invented one', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith([_sent(to: null)]),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('Someone has not answered yet'), findsOneWidget);
    });

    testWidgets('more than one is counted, and only pending ones are shown', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith([
          _sent(),
          _sent(id: 'req-2', to: 'carol', daysAgo: 0),
          // Already answered, or taken back earlier: nothing to wait for
          // and nothing to withdraw.
          _sent(id: 'req-3', to: 'dave', status: 'declined'),
          _sent(id: 'req-4', to: 'erin', status: 'cancelled'),
        ]),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('Waiting for 2 answers'), findsOneWidget);
      expect(find.text('dave has not answered yet'), findsNothing);
      expect(find.text('erin has not answered yet'), findsNothing);
    });

    testWidgets('a device that never signed in is shown none of this, even '
        'if something is somehow cached', (tester) async {
      final signedOut = FakeAccountClient(requests: _snapshotWith([_sent()]));

      await _pumpFriendsScreen(tester, _containerWith(signedOut));

      expect(find.text('Waiting for an answer'), findsNothing);
      expect(find.text('bob has not answered yet'), findsNothing);
    });

    testWidgets('nothing at all is shown when nothing is waiting', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith(const []),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('Waiting for an answer'), findsNothing);
    });
  });

  group('taking one back', () {
    testWidgets('asks first, and the question never reads like unfriending', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith([_sent()]),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel request'));
      await tester.pumpAndSettle();

      expect(find.text('Take back your request to bob?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('does not remove anyone'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('you are not friends yet'),
        ),
        findsOneWidget,
      );
      expect(client.cancelledRequests, isEmpty);
    });

    testWidgets('backing out of that question leaves the request alone', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith([_sent()]),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));
      await _cancelRequest(tester, confirm: 'Keep waiting');

      expect(client.cancelledRequests, isEmpty);
      expect(find.text('bob has not answered yet'), findsOneWidget);
    });

    testWidgets('confirming withdraws exactly that request, says so, and it '
        'is gone', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith([
          _sent(),
          _sent(id: 'req-2', to: 'carol', daysAgo: 1),
        ]),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));
      // The first row is bob's.
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('bob has not answered yet'),
            matching: find.byType(ListTile),
          ),
          matching: find.widgetWithText(TextButton, 'Cancel request'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Take it back'));
      await tester.pumpAndSettle();

      expect(client.cancelledRequests, ['req-1']);
      expect(find.text('Took back your request to bob.'), findsOneWidget);
      expect(find.text('bob has not answered yet'), findsNothing);
      expect(find.text('carol has not answered yet'), findsOneWidget);
    });

    testWidgets('one they already answered says so instead of failing '
        'obscurely, and the list stops showing it', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith([_sent()]),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      // The world moved on while this screen was open: bob answered, so the
      // service refuses to cancel and the next read no longer lists it.
      client
        ..cancelError = const AccountClientException(
          409,
          'That request has already been answered',
        )
        ..requests = _snapshotWith(const []);

      await _cancelRequest(tester, confirm: 'Take it back');

      expect(
        find.text('bob had already answered that request.'),
        findsOneWidget,
      );
      expect(find.text('bob has not answered yet'), findsNothing);
    });

    testWidgets('any other failure keeps the request on screen, since it is '
        'still live', (tester) async {
      final client =
          FakeAccountClient(
              account: _signedIn,
              requests: _snapshotWith([_sent()]),
            )
            ..cancelError = const AccountClientException(
              503,
              'Could not reach the account service',
            );

      await _pumpFriendsScreen(tester, _containerWith(client));
      await _cancelRequest(tester, confirm: 'Take it back');

      expect(
        find.text('Could not take that request back right now. Try again.'),
        findsOneWidget,
      );
      expect(find.text('bob has not answered yet'), findsOneWidget);
      // Never in the server's own words, which name internal machinery.
      expect(find.textContaining('account service'), findsNothing);
    });
  });

  group('honesty about how fresh the lists are', () {
    testWidgets('a stale answer still shows what was sent, and the screen '
        'still admits it could not check', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        requests: _snapshotWith([_sent()], live: false),
      );

      await _pumpFriendsScreen(tester, _containerWith(client));

      expect(find.text('bob has not answered yet'), findsOneWidget);
      // Said once, by the section above, and about both lists — they come
      // from the same fetch.
      expect(find.textContaining('Could not check'), findsOneWidget);
    });
  });
}
