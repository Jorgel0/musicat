import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicat/core/embedded_server/default_relay.dart';
import 'package:musicat/core/network/federation/account_client.dart';
import 'package:musicat/features/friends/domain/musicat_server_config.dart';
import 'package:musicat/features/friends/presentation/account_devices_screen.dart';
import 'package:musicat/features/friends/presentation/account_screen.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';

import 'fakes/fake_account_client.dart';

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

/// The three shapes a row can have: the device asking, another device that
/// reported what it is, and one that never did. Node ids are deliberately
/// recognisable strings so a test can assert none of them reaches the
/// screen.
AccountDevice _device({
  required String nodeId,
  String? deviceName,
  bool isThisDevice = false,
  int daysAgo = 0,
  Duration? lastUsed,
}) => AccountDevice(
  nodeId: nodeId,
  linkedAt: DateTime.now().subtract(Duration(days: daysAgo)),
  deviceName: deviceName,
  isThisDevice: isThisDevice,
  lastLoginAt: lastUsed == null ? null : DateTime.now().subtract(lastUsed),
);

ProviderContainer _containerWith(FakeAccountClient client) {
  final container = ProviderContainer(
    overrides: [
      accountClientProvider.overrideWithValue(client),
      musicatServerConfigControllerProvider.overrideWith(
        () => MusicatServerConfigController(_configured),
      ),
      defaultRelayUrlProvider.overrideWithValue('ws://relay.test:8090/connect'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Mounts the real account screen and pushes the real device screen on top
/// of it, the way the app does — so "unlinking this device signs you out"
/// can be checked by where the user actually ends up, not by a provider's
/// value.
Future<void> _pumpDevicesScreen(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final router = GoRouter(
    initialLocation: '/account',
    routes: [
      GoRoute(
        path: '/account',
        builder: (context, state) => const AccountScreen(),
        routes: [
          GoRoute(
            path: 'devices',
            builder: (context, state) => const AccountDevicesScreen(),
          ),
        ],
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
  router.push('/account/devices');
  await tester.pumpAndSettle();
}

/// Taps the Unlink button on the row titled [deviceLabel].
Future<void> _tapUnlinkOn(WidgetTester tester, String deviceLabel) async {
  final row = find.ancestor(
    of: find.text(deviceLabel),
    matching: find.byType(ListTile),
  );
  await tester.tap(
    find.descendant(
      of: row,
      matching: find.widgetWithText(TextButton, 'Unlink'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('seeing the devices on your account', () {
    testWidgets('two devices of the same kind, linked the same day, are still '
        'tellable apart by when each was last used', (tester) async {
      // The exact case that made this screen useless: both rows read
      // "Linux · Added today", and the one question the screen exists to
      // answer is which of them is the machine you still have.
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [
          _device(
            nodeId: 'n-here',
            deviceName: 'Linux',
            isThisDevice: true,
            lastUsed: const Duration(minutes: 1),
          ),
          _device(
            nodeId: 'n-old',
            deviceName: 'Linux',
            lastUsed: const Duration(days: 200),
          ),
        ],
      );
      final container = _containerWith(client);

      await _pumpDevicesScreen(tester, container);

      expect(find.textContaining('Used just now'), findsOneWidget);
      expect(find.textContaining('Not used for 6 months'), findsOneWidget);
      // And the added-date, which separates them not at all, is not what
      // the rows lead with any more.
      expect(find.textContaining('Added today'), findsNothing);
    });

    testWidgets('a server too old to report recency still shows the date, '
        'rather than an empty line', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [_device(nodeId: 'n-1', deviceName: 'Android', daysAgo: 3)],
      );
      final container = _containerWith(client);

      await _pumpDevicesScreen(tester, container);

      expect(find.textContaining('Added 3 days ago'), findsOneWidget);
    });

    testWidgets('names each one in terms a person can recognise, marks the '
        'one they are holding, and never shows a node id', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [
          _device(nodeId: 'node-phone', deviceName: 'Android', daysAgo: 40),
          _device(nodeId: 'node-here', deviceName: 'Linux', isThisDevice: true),
          // The device that never reported what it is: shown honestly, not
          // as its node id and not as an invented name.
          _device(nodeId: 'node-mystery', daysAgo: 3),
        ],
      );

      await _pumpDevicesScreen(tester, _containerWith(client));

      expect(find.text('Android'), findsOneWidget);
      expect(find.text('Linux'), findsOneWidget);
      expect(find.text('Unknown device'), findsOneWidget);

      // Which one is this one, and when each arrived — the two things that
      // tell otherwise-identical devices apart.
      expect(find.text('This device · Added today'), findsOneWidget);
      expect(find.text('Added a month ago'), findsOneWidget);
      expect(find.text('Added 3 days ago'), findsOneWidget);

      expect(find.textContaining('node-'), findsNothing);
      expect(
        find.text('3 devices are signed in to your account.'),
        findsOneWidget,
      );
    });

    testWidgets('says what a device on this list is actually able to do, '
        'since that is what makes unlinking one worth doing', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [
          _device(nodeId: 'node-here', deviceName: 'Linux', isThisDevice: true),
        ],
      );

      await _pumpDevicesScreen(tester, _containerWith(client));

      expect(find.textContaining('can act as you'), findsOneWidget);
      expect(
        find.text('One device is signed in to your account.'),
        findsOneWidget,
      );
    });
  });

  group('unlinking another device', () {
    testWidgets('asks first, names the device, and says the two things that '
        'are easy to get wrong', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [
          _device(nodeId: 'node-phone', deviceName: 'Android', daysAgo: 40),
          _device(nodeId: 'node-here', deviceName: 'Linux', isThisDevice: true),
        ],
      );

      await _pumpDevicesScreen(tester, _containerWith(client));
      await _tapUnlinkOn(tester, 'Android');

      expect(find.text('Unlink Android?'), findsOneWidget);
      // It stops being able to act as the account...
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining(
            'stops being able to act as your '
            'account',
          ),
        ),
        findsOneWidget,
      );
      // ...and nobody warns it, which is the part a user would otherwise
      // assume the opposite of.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('It is not told'),
        ),
        findsOneWidget,
      );
      // Nothing has happened yet.
      expect(client.unlinkedNodeIds, isEmpty);
    });

    testWidgets('cancelling the confirmation unlinks nothing at all', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [
          _device(nodeId: 'node-phone', deviceName: 'Android', daysAgo: 40),
          _device(nodeId: 'node-here', deviceName: 'Linux', isThisDevice: true),
        ],
      );

      await _pumpDevicesScreen(tester, _containerWith(client));
      await _tapUnlinkOn(tester, 'Android');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(client.unlinkedNodeIds, isEmpty);
      expect(find.text('Android'), findsOneWidget);
    });

    testWidgets('confirming unlinks exactly that device, says so, and drops '
        'it from the list', (tester) async {
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [
          _device(nodeId: 'node-phone', deviceName: 'Android', daysAgo: 40),
          _device(nodeId: 'node-here', deviceName: 'Linux', isThisDevice: true),
        ],
      );

      await _pumpDevicesScreen(tester, _containerWith(client));
      await _tapUnlinkOn(tester, 'Android');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlink'));
      await tester.pumpAndSettle();

      expect(client.unlinkedNodeIds, ['node-phone']);
      expect(
        find.text('Android is no longer linked to your account.'),
        findsOneWidget,
      );
      expect(find.text('Android'), findsNothing);
      // Still signed in here: unlinking somebody else's device is not a
      // sign-out.
      expect(find.text('Linux'), findsOneWidget);
    });

    testWidgets('a failure says plainly that nothing was unlinked, and the '
        'device stays on the list', (tester) async {
      final client =
          FakeAccountClient(
              account: _signedIn,
              devices: [
                _device(
                  nodeId: 'node-phone',
                  deviceName: 'Android',
                  daysAgo: 40,
                ),
                _device(
                  nodeId: 'node-here',
                  deviceName: 'Linux',
                  isThisDevice: true,
                ),
              ],
            )
            ..unlinkError = const AccountClientException(
              503,
              'Could not reach the account service',
              code: 'service_unreachable',
            );

      await _pumpDevicesScreen(tester, _containerWith(client));
      await _tapUnlinkOn(tester, 'Android');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlink'));
      await tester.pumpAndSettle();

      expect(find.textContaining('nothing was unlinked'), findsOneWidget);
      // Never in the server's own words, which name internal machinery.
      expect(find.textContaining('account service'), findsNothing);
      expect(find.text('Android'), findsOneWidget);
    });
  });

  group('unlinking the device you are on', () {
    testWidgets('warns that it signs you out here, and that friends stay', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [
          _device(nodeId: 'node-here', deviceName: 'Linux', isThisDevice: true),
        ],
      );

      await _pumpDevicesScreen(tester, _containerWith(client));
      await _tapUnlinkOn(tester, 'Linux');

      expect(find.text('Unlink this device?'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('signs you out here'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('Your friends stay on this device'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('lands back on the account screen, signed out, instead of '
        'leaving a signed-in shell that can no longer do anything', (
      tester,
    ) async {
      final client = FakeAccountClient(
        account: _signedIn,
        devices: [
          _device(nodeId: 'node-phone', deviceName: 'Android', daysAgo: 40),
          _device(nodeId: 'node-here', deviceName: 'Linux', isThisDevice: true),
        ],
      );

      await _pumpDevicesScreen(tester, _containerWith(client));
      await _tapUnlinkOn(tester, 'Linux');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlink'));
      await tester.pumpAndSettle();

      expect(client.unlinkedNodeIds, ['node-here']);
      // Off the device list — which this device may no longer read — and on
      // the screen that now offers signing back in.
      expect(find.text('Your devices'), findsNothing);
      expect(find.text('Sign in or create an account'), findsOneWidget);
      // And told what just happened, including the part that would
      // otherwise be frightening.
      expect(
        find.textContaining(
          'This device is no longer linked to your '
          'account',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Your friends are still here'),
        findsOneWidget,
      );
    });
  });

  group('when the list cannot be read', () {
    testWidgets('shows no list at all, says why, and offers to ask again', (
      tester,
    ) async {
      final client =
          FakeAccountClient(
              account: _signedIn,
              devices: [
                _device(
                  nodeId: 'node-here',
                  deviceName: 'Linux',
                  isThisDevice: true,
                ),
              ],
            )
            ..devicesError = const AccountClientException(
              503,
              'Could not reach the account service',
              code: 'service_unreachable',
            );

      await _pumpDevicesScreen(tester, _containerWith(client));

      expect(
        find.textContaining('never shows an older list here'),
        findsOneWidget,
      );
      expect(find.text('Linux'), findsNothing);
      expect(find.textContaining('account service'), findsNothing);

      // Asking again is the user's move, and it works.
      client.devicesError = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Linux'), findsOneWidget);
    });

    testWidgets('does not quietly turn into a poll: a failure is asked about '
        'once and then left alone', (tester) async {
      // Riverpod 3 retries a failed provider on a backoff timer by default,
      // which here would be an invisible stream of calls to the account
      // service. Counted structurally rather than trusted.
      final client = FakeAccountClient(account: _signedIn)
        ..devicesError = const AccountClientException(
          503,
          'Could not reach the account service',
        );

      await _pumpDevicesScreen(tester, _containerWith(client));
      expect(client.deviceListCalls, 1);

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(client.deviceListCalls, 1);

      // The inverse, so this cannot pass by never asking at all: the retry
      // the user *does* ask for goes through.
      await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
      await tester.pumpAndSettle();
      expect(client.deviceListCalls, 2);
    });
  });
}
