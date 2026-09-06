import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/password_hashing.dart';
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
        password: 'hunter2-ok',
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
          password: 'hunter2-ok',
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
          password: 'hunter2-ok',
          nodeId: 'node-a',
          publicKeyBase64: 'key-a',
        );

        final second = await store.loginOrSignup(
          username: 'alice',
          password: 'hunter2-ok',
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
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      final result = await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2-ok',
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
        password: 'hunter2-ok',
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
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );
      await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2-ok',
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
        password: 'hunter2-ok',
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

  group('one device, one account at a time', () {
    test('logging in as a second account moves this device off the first, '
        'so it stops authenticating as somebody it left', () async {
      final first = await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      final second = await store.loginOrSignup(
        username: 'bob',
        password: 'hunter3-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      expect(second.outcome, LoginOutcome.created);
      // The lookup every account route authenticates through.
      expect(await store.findByDeviceNodeId('node-a'), isNotNull);
      expect((await store.findByDeviceNodeId('node-a'))!.username, 'bob');
      expect(
        (await store.findById(first.account!.accountId))!.devices,
        isEmpty,
        reason:
            'the device stayed linked to both accounts, so which one it '
            'acts for depends on file order',
      );
      // Both accounts still exist, and the one left behind is perfectly
      // usable again -- its password still works and re-links a device.
      expect(await store.loadAll(), hasLength(2));
    });

    test('and back again: the first account is not lost, just left', () async {
      await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );
      await store.loginOrSignup(
        username: 'bob',
        password: 'hunter3-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      final back = await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      expect(back.outcome, LoginOutcome.linked);
      expect((await store.findByDeviceNodeId('node-a'))!.username, 'alice');
      expect((await store.findByUsername('bob'))!.devices, isEmpty);
    });

    test(
      'a wrong password moves nothing -- the device stays where it was',
      () async {
        await store.loginOrSignup(
          username: 'alice',
          password: 'hunter2-ok',
          nodeId: 'node-a',
          publicKeyBase64: 'key-a',
        );
        await store.loginOrSignup(
          username: 'bob',
          password: 'hunter3-ok',
          nodeId: 'node-b',
          publicKeyBase64: 'key-b',
        );

        final refused = await store.loginOrSignup(
          username: 'bob',
          password: 'not-bobs-password',
          nodeId: 'node-a',
          publicKeyBase64: 'key-a',
        );

        expect(refused.outcome, LoginOutcome.wrongPassword);
        expect((await store.findByDeviceNodeId('node-a'))!.username, 'alice');
        expect(
          (await store.findByUsername('bob'))!.devices.map((d) => d.nodeId),
          ['node-b'],
        );
      },
    );

    test("a device already on the target account, with nothing else to "
        'change, still gets unlinked from a third one', () async {
      // The idempotent re-login path -- same relayUrl, nothing to write --
      // which used to return before saving anything.
      await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );
      await store.loginOrSignup(
        username: 'bob',
        password: 'hunter3-ok',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );
      // Hand-made overlap: `node-b` linked to both, which is exactly the
      // state a pre-fix `accounts.json` can be sitting in right now.
      final alice = (await store.findByUsername('alice'))!;
      await store.loginOrSignup(
        username: 'alice',
        password: 'hunter2-ok',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );
      expect((await store.findById(alice.accountId))!.devices, hasLength(2));

      final relogin = await store.loginOrSignup(
        username: 'bob',
        password: 'hunter3-ok',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );

      expect(relogin.outcome, LoginOutcome.linked);
      expect((await store.findByDeviceNodeId('node-b'))!.username, 'bob');
      expect(
        (await store.findById(alice.accountId))!.devices.map((d) => d.nodeId),
        ['node-a'],
      );
    });
  });

  group('usernames are case-insensitive', () {
    test('an account is stored, and echoed back, under one canonical '
        'spelling', () async {
      final result = await store.loginOrSignup(
        username: 'Jorge',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      expect(result.account!.username, 'jorge');
      expect(await store.findByUsername('JORGE'), isNotNull);
      expect(await store.findByUsername('jorge'), isNotNull);
    });

    test('a different capitalization logs in to the same account instead of '
        'silently creating a second one', () async {
      final created = await store.loginOrSignup(
        username: 'jorge',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      final second = await store.loginOrSignup(
        username: 'Jorge',
        password: 'hunter2-ok',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );

      expect(second.outcome, LoginOutcome.linked);
      expect(second.account!.accountId, created.account!.accountId);
      expect(await store.loadAll(), hasLength(1));
      expect(second.account!.devices, hasLength(2));
    });

    test('two pre-existing accounts differing only by case are reported, not '
        'merged and not shadowed', () async {
      // Only reachable through data written before this rule existed, so it
      // is written the same way -- straight into the file.
      await store.loginOrSignup(
        username: 'jorge',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );
      final file = File('${tempDir.path}/accounts.json');
      final raw = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      final clone = Map<String, dynamic>.from(raw.single as Map)
        ..['accountId'] = 'second-account'
        ..['username'] = 'Jorge'
        ..['devices'] = <dynamic>[];
      file.writeAsStringSync(jsonEncode([...raw, clone]));

      final result = await store.loginOrSignup(
        username: 'jorge',
        password: 'hunter2-ok',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );

      expect(result.outcome, LoginOutcome.ambiguousUsername);
      // Nothing was merged, renamed or dropped: both are still there, and
      // both are still visible for an operator to sort out.
      expect(await store.loadAll(), hasLength(2));
      expect(await store.findAllByUsername('JORGE'), hasLength(2));
      // The exact spelling still resolves deterministically, so lookups
      // (a friend request by username) do not silently pick one at random.
      expect(
        (await store.findByUsername('Jorge'))!.accountId,
        'second-account',
      );
      expect(await store.findByUsername('JORGE'), isNull);
    });
  });

  group('creating an account is opt-in, and has a password floor', () {
    test('allowCreate: false refuses an unknown username without writing or '
        'hashing anything', () async {
      final result = await store.loginOrSignup(
        username: 'nobody',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
        allowCreate: false,
      );

      expect(result.outcome, LoginOutcome.noSuchAccount);
      expect(result.account, isNull);
      expect(await store.loadAll(), isEmpty);
    });

    test(
      'allowCreate: false still logs in to an account that exists',
      () async {
        await store.loginOrSignup(
          username: 'alice',
          password: 'hunter2-ok',
          nodeId: 'node-a',
          publicKeyBase64: 'key-a',
        );

        final result = await store.loginOrSignup(
          username: 'alice',
          password: 'hunter2-ok',
          nodeId: 'node-b',
          publicKeyBase64: 'key-b',
          allowCreate: false,
        );

        expect(result.outcome, LoginOutcome.linked);
      },
    );

    test('a new account cannot be created with a password shorter than the '
        'minimum', () async {
      final result = await store.loginOrSignup(
        username: 'alice',
        password: 'a' * (minPasswordLength - 1),
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );

      expect(result.outcome, LoginOutcome.passwordTooShort);
      expect(await store.loadAll(), isEmpty);
    });

    test('an account whose password predates the minimum can still log in -- '
        'the rule applies to creation only', () async {
      // The only way to get one now, and exactly what an existing
      // `accounts.json` holds: created before the floor existed.
      final legacy = AccountStore(tempDir);
      final file = File('${tempDir.path}/accounts.json');
      await legacy.loginOrSignup(
        username: 'alice',
        password: 'hunter2-ok',
        nodeId: 'node-a',
        publicKeyBase64: 'key-a',
      );
      expect(file.existsSync(), isTrue);
      // Re-hash a one-character password into the stored account, since the
      // store will never write one itself again.
      final hashed = await hashPassword('x');
      final raw = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      final account = Map<String, dynamic>.from(raw.single as Map)
        ..['passwordHashBase64'] = base64Encode(hashed.hash)
        ..['passwordSaltBase64'] = base64Encode(hashed.salt)
        ..['argon2Params'] = hashed.params.toJson();
      file.writeAsStringSync(jsonEncode([account]));

      final result = await store.loginOrSignup(
        username: 'alice',
        password: 'x',
        nodeId: 'node-b',
        publicKeyBase64: 'key-b',
      );

      expect(result.outcome, LoginOutcome.linked);
    });
  });

  test('persists accounts across store instances', () async {
    await store.loginOrSignup(
      username: 'alice',
      password: 'hunter2-ok',
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
      password: 'hunter2-ok',
      nodeId: 'node-a',
      publicKeyBase64: 'key-a',
    );
    expect(result.outcome, LoginOutcome.invalidUsername);
    expect(usernamePattern.hasMatch('not valid!'), isFalse);
  });
}
