import 'dart:io';

import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/relay/username_directory_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late AccountStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'musicat_account_store_test_',
    );
    store = AccountStore(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('loginOrSignup', () {
    test('creates a brand-new account and links the given device', () async {
      final result = await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      expect(result.outcome, LoginOutcome.created);
      expect(result.account!.username, 'alice');
      expect(result.account!.devices, hasLength(1));
      expect(result.account!.devices.single.nodeId, 'node-a');

      final persisted = await store.findByUsername('alice');
      expect(persisted, isNotNull);
      expect(persisted!.accountId, result.account!.accountId);
    });

    test(
      'rejects an invalid-format username without creating anything',
      () async {
        final result = await store.loginOrSignup(
          username: 'ab', // too short
          password: 'hunter2',
          nodeId: 'node-a',
          publicKeyBase64: 'key-a',
        );

        expect(result.outcome, LoginOutcome.invalidUsername);
        expect(result.account, isNull);
        expect(await store.findByUsername('ab'), isNull);
      },
    );

    test(
      'a second call with the correct password and a different nodeId links '
      'that device too (multi-device, not one-active-with-supersession)',
      () async {
        final first = await store.loginOrSignup(
          username: 'alice',
          password: 'hunter2',
          nodeId: 'node-a',
          publicKeyBase64: 'key-a',
        );

        final second = await store.loginOrSignup(
          username: 'alice',
          password: 'hunter2',
          nodeId: 'node-b',
          publicKeyBase64: 'key-b',
        );

        expect(second.outcome, LoginOutcome.linked);
        expect(second.account!.accountId, first.account!.accountId);
        final nodeIds = second.account!.devices.map((d) => d.nodeId).toSet();
        expect(nodeIds, {'node-a', 'node-b'});
      },
    );

    test('re-linking an already-linked device is idempotent', () async {
      await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      final result = await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      expect(result.outcome, LoginOutcome.linked);
      expect(result.account!.devices, hasLength(1));
    });

    test('the wrong password for an existing account fails and does not '
        'create a duplicate account or corrupt the existing one', () async {
      await store.loginOrSignup(
        username: 'alice',
        password: 'correct-password',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      final wrongAttempt = await store.loginOrSignup(
        username: 'alice',
        password: 'wrong-password',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );

      expect(wrongAttempt.outcome, LoginOutcome.wrongPassword);
      expect(wrongAttempt.account, isNull);

      final accounts = await store.loadAll();
      expect(accounts, hasLength(1));
      expect(accounts.single.devices, hasLength(1));
      expect(accounts.single.devices.single.nodeId, 'node-a');

      // The real password still works afterward.
      final retry = await store.loginOrSignup(
        username: 'alice',
        password: 'correct-password',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );
      expect(retry.outcome, LoginOutcome.linked);
    });

    test(
      'two concurrent signups for the same brand-new username with '
      'different passwords: exactly one creates the account, the other '
      'fails with wrongPassword instead of creating a second, conflicting '
      'account (regression-style test mirroring '
      "UsernameDirectoryStore.claim's own issue #8 regression test)",
      () async {
        for (var i = 0; i < 8; i++) {
          final username = 'racer$i';
          final results = await Future.wait([
            store.loginOrSignup(
              username: username,
              password: 'password-A',
              nodeId: 'node-A',
              publicKeyBase64: 'key-A',
            ),
            store.loginOrSignup(
              username: username,
              password: 'password-B',
              nodeId: 'node-B',
              publicKeyBase64: 'key-B',
            ),
          ]);

          final successes = results.where((r) => r.account != null).toList();
          expect(
            successes,
            hasLength(1),
            reason:
                'exactly one of the two concurrent signups for "$username" '
                'must succeed',
          );
          final failure = results.firstWhere((r) => r.account == null);
          expect(failure.outcome, LoginOutcome.wrongPassword);

          final accounts = await store.loadAll();
          final createdForThisUsername = accounts.where(
            (a) => a.username == username,
          );
          expect(
            createdForThisUsername,
            hasLength(1),
            reason: 'exactly one account for "$username" must exist',
          );
          expect(createdForThisUsername.single.devices, hasLength(1));
        }
      },
    );

    test('many concurrent signups for the same brand-new username with the '
        'same password and different nodeIds all succeed and converge onto '
        'one account with every device linked', () async {
      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          store.loginOrSignup(
            username: 'alice',
            password: 'shared-password',
            nodeId: 'node-$i',
            publicKeyBase64: 'key-$i',
          ),
      ]);

      expect(results.every((r) => r.account != null), isTrue);

      final accounts = await store.loadAll();
      expect(accounts, hasLength(1));
      expect(accounts.single.devices, hasLength(5));
    });
  });

  group('findByDeviceNodeId', () {
    test('resolves the account owning a linked device', () async {
      await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      final found = await store.findByDeviceNodeId('node-a');
      expect(found?.username, 'alice');
    });

    test('returns null for a nodeId never linked to any account', () async {
      expect(await store.findByDeviceNodeId('never-linked'), isNull);
    });
  });

  group('unlinkDevice', () {
    test('removes a linked device', () async {
      final result = await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );
      await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );

      final removed = await store.unlinkDevice(
        result.account!.accountId,
        'node-b',
      );
      expect(removed, isTrue);

      final updated = await store.findById(result.account!.accountId);
      expect(updated!.devices.map((d) => d.nodeId), ['node-a']);
    });

    test('unlinking an already-unlinked device is a no-op success', () async {
      final result = await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      final removed = await store.unlinkDevice(
        result.account!.accountId,
        'never-linked',
      );
      expect(removed, isTrue);
      expect(
        (await store.findById(result.account!.accountId))!.devices,
        hasLength(1),
      );
    });

    test('returns false for an unknown accountId', () async {
      expect(await store.unlinkDevice('unknown-account', 'node-a'), isFalse);
    });
  });

  test('persists accounts across store instances', () async {
    await store.loginOrSignup(
      username: 'alice',
      password: 'hunter2',
      nodeId: 'node-a',
      publicKeyBase64: 'key-a',
    );

    final reloaded = AccountStore(tempDir);
    final found = await reloaded.findByUsername('alice');
    expect(found, isNotNull);
    expect(found!.devices.single.nodeId, 'node-a');
  });

  test('accounts and the existing username directory share the same format '
      'rule', () async {
    final result = await store.loginOrSignup(
      username: 'not valid!',
      password: 'hunter2',
      nodeId: 'node-a',
      publicKeyBase64: 'key-a',
    );
    expect(result.outcome, LoginOutcome.invalidUsername);
    expect(usernamePattern.hasMatch('not valid!'), isFalse);
  });
}
