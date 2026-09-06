import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicat/core/embedded_server/default_relay.dart';
import 'package:musicat/core/network/federation/account_client.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/account_screen.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';

import 'fakes/fake_account_client.dart';

/// A fresh install on a platform that runs the built-in server: nothing
/// configured at all, and in particular no relay of the user's own — the
/// exact state the "zero configuration" requirement is about.
const _freshInstall = MusicatServerConfig(
  host: '',
  port: 8080,
  myPublicAddress: '',
  useEmbeddedServer: true,
);

/// Someone who already self-hosts, pointing at their own separate server.
/// This app cannot know what relay *that* server has, so it never claims
/// there is none.
const _selfHostedServer = MusicatServerConfig(
  host: 'nas.example',
  port: 9090,
  myPublicAddress: 'me.example:9090',
);

/// Mounts [AccountScreen] behind a real (if tiny) go_router, because the
/// screen pops itself after a successful sign-in — `context.canPop()`/
/// `context.pop()` are go_router's, and a bare `MaterialApp(home:)` has no
/// router for them to ask. Starting at `/` and pushing `/account` is also
/// what actually happens in the app (the Friends screen pushes it), so the
/// pop-on-success behaviour is exercised for real rather than skipped.
Future<void> _pumpAccountScreen(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: Text('Friends')),
      ),
      GoRoute(
        path: '/account',
        builder: (context, state) => const AccountScreen(),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  router.push('/account');
  await tester.pumpAndSettle();
}

/// [defaultRelay] stands in for `defaultRelayUrl` — the one constant a
/// build fills in to ship a relay. Overridden here rather than read from
/// the constant so both cases are covered whichever way it happens to be
/// set in this build (it is empty today).
ProviderContainer _containerWith(
  FakeAccountClient client, {
  MusicatServerConfig config = MusicatServerConfig.empty,
  String defaultRelay = 'ws://relay.test:8090/connect',
}) {
  final container = ProviderContainer(
    overrides: [
      accountClientProvider.overrideWithValue(client),
      musicatServerConfigControllerProvider.overrideWith(
        () => MusicatServerConfigController(config),
      ),
      defaultRelayUrlProvider.overrideWithValue(defaultRelay),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _signIn(
  WidgetTester tester, {
  String username = 'jorge',
  String password = 'hunter2',
}) async {
  await tester.enterText(find.widgetWithText(TextField, 'Username'), username);
  await tester.enterText(find.widgetWithText(TextField, 'Password'), password);
  await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
  await tester.pumpAndSettle();
}

void main() {
  group('signing in', () {
    testWidgets('an existing account signs this device in, in one form with '
        'no sign-up/sign-in split to choose from first', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'});
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);

      expect(find.text('Sign in or create an account'), findsOneWidget);
      expect(find.byType(Tab), findsNothing);

      await _signIn(tester);

      // Asked without permission to create anything — the account was
      // already there, so nothing more was needed.
      expect(client.signInCalls, [
        (username: 'jorge', password: 'hunter2', allowCreate: false),
      ]);
      expect(find.text('Signed in as jorge.'), findsOneWidget);
      expect(find.textContaining('Account created'), findsNothing);
      // Popped back to where it was opened from.
      expect(find.text('Friends'), findsOneWidget);
    });

    testWidgets('trims the username before sending it', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'});
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester, username: '  jorge  ');

      expect(client.signInCalls.single.username, 'jorge');
    });

    testWidgets('refuses to send an empty form, without calling the server', (
      tester,
    ) async {
      final client = FakeAccountClient();
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a username and a password.'), findsOneWidget);
      expect(client.signInCalls, isEmpty);
    });
  });

  group('a typo can no longer become a second, empty account', () {
    testWidgets('an unknown username is not created silently: it asks, '
        'naming the username', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'});
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester, username: 'Jorgee');

      // One call, and it explicitly refused to create anything.
      expect(client.signInCalls, [
        (username: 'Jorgee', password: 'hunter2', allowCreate: false),
      ]);
      expect(find.text('Create the account "Jorgee"?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('check the username for typos'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('cancelling creates nothing at all, and leaves the form to '
        'fix', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'});
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester, username: 'Jorgee');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(client.signInCalls.length, 1);
      expect(client.account, isNull);
      // Still on the form, with what was typed still there to correct.
      expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
      expect(find.textContaining('Account created'), findsNothing);
    });

    testWidgets('confirming creates it — the only path that ever does — and '
        'says so', (tester) async {
      final client = FakeAccountClient();
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester, username: 'newcomer');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(client.signInCalls, [
        (username: 'newcomer', password: 'hunter2', allowCreate: false),
        (username: 'newcomer', password: 'hunter2', allowCreate: true),
      ]);
      expect(
        find.text('Account created — you are signed in as newcomer.'),
        findsOneWidget,
      );
      expect(find.text('Friends'), findsOneWidget);
    });

    testWidgets('a password too short to create with says the minimum, in '
        'the words of whoever knows it', (tester) async {
      final client = FakeAccountClient()
        ..createError = const AccountClientException(
          400,
          'Password must be at least 10 characters.',
        );
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester, username: 'newcomer', password: 'short');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(
        find.text('Password must be at least 10 characters.'),
        findsOneWidget,
      );
      // Not swallowed by the username rule, which is the other 400.
      expect(find.textContaining('3 to 32 characters'), findsNothing);
      expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    });
  });

  group('when there is nowhere to sign in to', () {
    testWidgets('a fresh install with a relay that ships in the build needs '
        'no configuration at all: the form is right there, and works', (
      tester,
    ) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'});
      final container = _containerWith(client, config: _freshInstall);

      await _pumpAccountScreen(tester, container);

      expect(find.text('Sign in or create an account'), findsOneWidget);
      expect(find.textContaining('Accounts need a relay'), findsNothing);

      await _signIn(tester);

      expect(find.text('Signed in as jorge.'), findsOneWidget);
    });

    testWidgets('a build with no relay of its own says so plainly instead of '
        'offering a form that cannot work', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'});
      final container = _containerWith(
        client,
        config: _freshInstall,
        defaultRelay: '',
      );

      await _pumpAccountScreen(tester, container);

      expect(find.text('Accounts need a relay'), findsOneWidget);
      expect(
        find.textContaining('Ask whoever gave you Musicat'),
        findsOneWidget,
      );
      // No dead end: the form that could only ever fail is not offered,
      // and the other way of adding friends is named.
      expect(find.widgetWithText(FilledButton, 'Continue'), findsNothing);
      expect(find.textContaining('invite code'), findsOneWidget);
      expect(client.signInCalls, isEmpty);
    });

    testWidgets('the user\'s own relay is enough on its own, with no relay '
        'in the build', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'});
      final container = _containerWith(
        client,
        config: _freshInstall.copyWith(relayUrl: 'ws://mine.example:8090/c'),
        defaultRelay: '',
      );

      await _pumpAccountScreen(tester, container);

      expect(find.text('Sign in or create an account'), findsOneWidget);
      expect(find.textContaining('Accounts need a relay'), findsNothing);
    });

    testWidgets('a separately self-hosted server is never told it has no '
        'relay — this app cannot know what that server has', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'});
      final container = _containerWith(
        client,
        config: _selfHostedServer,
        defaultRelay: '',
      );

      await _pumpAccountScreen(tester, container);

      expect(find.text('Sign in or create an account'), findsOneWidget);
      expect(find.textContaining('Accounts need a relay'), findsNothing);
    });
  });

  group('sign-in failures are told apart', () {
    testWidgets('an ambiguous username never tells the user to try again — '
        'retrying can never fix it', (tester) async {
      // Two accounts on the service differ only in capitalisation. Before
      // the server sent a code this arrived as a bare 5xx and was rendered
      // as "try again in a moment", which is advice that can never work:
      // only whoever runs the relay can resolve it.
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(
          409,
          'That username is held by two accounts',
          code: 'ambiguous_username',
        );
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(find.textContaining('two accounts share it'), findsOneWidget);
      expect(find.textContaining('will not help'), findsOneWidget);
      expect(find.textContaining('Try again in a moment'), findsNothing);
    });

    testWidgets('a too-short password is told apart from a bad username by '
        'the code, not by reading the sentence', (tester) async {
      // Deliberately worded so the old "does the message contain the word
      // password" sniff would get it wrong: this one never says it.
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(
          400,
          'Too short — use at least 8 characters',
          code: 'password_too_short',
        );
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(find.textContaining('at least 8 characters'), findsOneWidget);
      expect(find.textContaining('Choose a username'), findsNothing);
    });

    testWidgets('an invalid username is told apart the same way, even when '
        'the service happens to mention a password', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(
          400,
          'Invalid username format (this is not about your password)',
          code: 'invalid_username',
        );
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(find.textContaining('Choose a username'), findsOneWidget);
    });

    testWidgets('a node too old to send a code still gets sensible copy', (
      tester,
    ) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(401, 'Incorrect password');
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(
        find.textContaining('That password does not match'),
        findsOneWidget,
      );
    });

    testWidgets('a wrong password says so, and points at the way out', (
      tester,
    ) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(401, 'Incorrect password');
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(
        find.textContaining('That password does not match this username'),
        findsOneWidget,
      );
      // Still on the form, with the fields intact to try again.
      expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
    });

    testWidgets('being rate-limited says how long to wait, and never reads '
        'as a wrong password', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(
          429,
          'Too many failed attempts for this username. Try again later.',
        );
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(find.textContaining('Wait about a minute'), findsOneWidget);
      expect(find.textContaining('does not match'), findsNothing);
    });

    testWidgets('accounts being unavailable says it is not the password — '
        'the failure most likely to be misread', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(
          503,
          'Could not reach the account service',
        );
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(
        find.textContaining('this is not a problem with your password'),
        findsOneWidget,
      );
      // And never in the server's own words, which name internal machinery.
      expect(find.textContaining('account service'), findsNothing);
    });

    testWidgets('a 502 reads the same way as a 503: not the user\'s fault', (
      tester,
    ) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(502, 'upstream said no');
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(
        find.textContaining('this is not a problem with your password'),
        findsOneWidget,
      );
    });

    testWidgets('an unusable username spells out the rule', (tester) async {
      final client = FakeAccountClient(existingUsernames: {'jorge'})
        ..signInError = const AccountClientException(400, 'Invalid username');
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester, username: 'no');

      expect(find.textContaining('3 to 32 characters'), findsOneWidget);
    });
  });

  group('when already signed in', () {
    testWidgets('shows the username — the thing this app could never show '
        'its own user before', (tester) async {
      final client = FakeAccountClient(
        account: MyAccount(
          accountId: 'acc-1',
          username: 'jorge',
          loggedInAt: DateTime.utc(2026, 9, 5),
        ),
      );
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);

      expect(find.text('Signed in as'), findsOneWidget);
      expect(find.text('jorge'), findsOneWidget);
      // No account id anywhere on screen.
      expect(find.textContaining('acc-1'), findsNothing);
    });

    testWidgets('signing out says plainly that friends stay, and only then '
        'signs out', (tester) async {
      final client = FakeAccountClient(
        account: MyAccount(
          accountId: 'acc-1',
          username: 'jorge',
          loggedInAt: DateTime.utc(2026, 9, 5),
        ),
      );
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
      await tester.pumpAndSettle();

      // Scoped to the dialog: the screen behind it makes the same promise
      // in its own footer, and both saying it is the point.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('Your friends stay on this device'),
        ),
        findsOneWidget,
      );

      // Cancelling really cancels.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(client.signOutCalls, 0);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(client.signOutCalls, 1);
      // Back to the sign-in form, in the same screen.
      expect(find.text('Sign in or create an account'), findsOneWidget);
    });
  });
}
