import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicat/core/network/federation/account_client.dart';
import 'package:musicat/features/friends/presentation/account_screen.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';

import 'fakes/fake_account_client.dart';

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

ProviderContainer _containerWith(FakeAccountClient client) {
  final container = ProviderContainer(
    overrides: [accountClientProvider.overrideWithValue(client)],
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
    testWidgets('one form does both: a free username creates the account, '
        'and says so', (tester) async {
      final client = FakeAccountClient()..createdOnSignIn = true;
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);

      // No sign-up/sign-in split to choose between first.
      expect(find.text('Sign in or create an account'), findsOneWidget);
      expect(find.byType(Tab), findsNothing);

      await _signIn(tester);

      expect(client.signInCalls, [(username: 'jorge', password: 'hunter2')]);
      expect(
        find.text('Account created — you are signed in as jorge.'),
        findsOneWidget,
      );
      // Popped back to where it was opened from.
      expect(find.text('Friends'), findsOneWidget);
    });

    testWidgets('an existing username signs this device in instead, and says '
        'that', (tester) async {
      final client = FakeAccountClient()..createdOnSignIn = false;
      final container = _containerWith(client);

      await _pumpAccountScreen(tester, container);
      await _signIn(tester);

      expect(find.text('Signed in as jorge.'), findsOneWidget);
      expect(find.textContaining('Account created'), findsNothing);
    });

    testWidgets('trims the username before sending it', (tester) async {
      final client = FakeAccountClient();
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

  group('sign-in failures are told apart', () {
    testWidgets('a wrong password says so, and points at the way out', (
      tester,
    ) async {
      final client = FakeAccountClient()
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
      final client = FakeAccountClient()
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
      final client = FakeAccountClient()
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
      final client = FakeAccountClient()
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
      final client = FakeAccountClient()
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
