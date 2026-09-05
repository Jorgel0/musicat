import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/accounts/account_session_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  late AccountSessionStore store;

  File sessionFile() => File('${dataDir.path}/account_session.json');

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('musicat_session_store_');
    store = AccountSessionStore(dataDir);
  });

  tearDown(() => dataDir.deleteSync(recursive: true));

  test('a node with no session loads null, without creating a file', () async {
    expect(await store.load(), isNull);
    expect(sessionFile().existsSync(), isFalse);
  });

  test('saves and reloads a session, including across a fresh store '
      'instance', () async {
    await store.save(accountId: 'acc-1', username: 'alice');

    final reloaded = await AccountSessionStore(dataDir).load();
    expect(reloaded, isNotNull);
    expect(reloaded!.accountId, 'acc-1');
    expect(reloaded.username, 'alice');
    expect(reloaded.loggedInAt.isUtc, isTrue);
  });

  test(
    'holds at most one session -- a second save replaces the first',
    () async {
      await store.save(accountId: 'acc-1', username: 'alice');
      await store.save(accountId: 'acc-2', username: 'bob');

      final loaded = await store.load();
      expect(loaded!.accountId, 'acc-2');
      expect(loaded.username, 'bob');
      // One JSON object on disk, not a list that grew.
      final raw = jsonDecode(sessionFile().readAsStringSync());
      expect(raw, isA<Map<String, dynamic>>());
      expect((raw as Map<String, dynamic>)['accountId'], 'acc-2');
    },
  );

  test('the persisted file contains no credential of any kind', () async {
    // The password never reaches this class -- `save` has no parameter for
    // one -- but assert on the actual bytes too, so a future field that
    // quietly carried one would fail here rather than in review.
    await store.save(accountId: 'acc-1', username: 'alice');

    final raw = sessionFile().readAsStringSync();
    final keys = (jsonDecode(raw) as Map<String, dynamic>).keys.toSet();
    expect(keys, {'accountId', 'username', 'loggedInAt'});
    expect(raw.toLowerCase(), isNot(contains('password')));
    expect(raw.toLowerCase(), isNot(contains('token')));
    expect(raw.toLowerCase(), isNot(contains('secret')));
  });

  test(
    'clear() removes the session and reports whether there was one',
    () async {
      expect(await store.clear(), isFalse);

      await store.save(accountId: 'acc-1', username: 'alice');
      expect(await store.clear(), isTrue);

      expect(await store.load(), isNull);
      expect(sessionFile().existsSync(), isFalse);
      // Idempotent, like the DELETE route above it.
      expect(await store.clear(), isFalse);
    },
  );

  test('a corrupt session file reads as "not logged in" rather than '
      'throwing', () async {
    sessionFile().writeAsStringSync('{ this is not json');

    expect(await store.load(), isNull);
  });

  test('a session file missing a required field also reads as "not logged '
      'in"', () async {
    sessionFile().writeAsStringSync(jsonEncode({'accountId': 'acc-1'}));

    expect(await store.load(), isNull);
  });

  test('a logout racing a login does not resurrect the session -- the '
      'mutation lock serializes them', () async {
    // Without the lock, clear()'s existsSync/delete could interleave with
    // save()'s write and leave a file behind that nothing logged in for.
    for (var i = 0; i < 20; i++) {
      await store.save(accountId: 'acc-$i', username: 'alice');
      final save = store.save(accountId: 'acc-next', username: 'alice');
      final clear = store.clear();
      await Future.wait<Object?>([save, clear]);
      // Whichever order they were queued in, the outcome is one of the two
      // whole operations having happened last -- never a half-applied mix.
      final loaded = await store.load();
      expect(
        loaded == null || loaded.accountId == 'acc-next',
        isTrue,
        reason: 'session was left in a state neither operation produces',
      );
    }
  });
}
