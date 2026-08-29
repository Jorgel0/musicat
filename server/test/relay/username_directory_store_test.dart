import 'dart:io';

import 'package:musicat_server/src/relay/username_directory_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late UsernameDirectoryStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'musicat_username_directory_test_',
    );
    store = UsernameDirectoryStore(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('a fresh username has no owner', () async {
    expect(await store.lookup('alice'), isNull);
  });

  test('claiming a fresh username succeeds and it resolves back', () async {
    final result = await store.claim('alice', 'node-a');

    expect(result.success, isTrue);
    expect(result.error, isNull);
    expect(await store.lookup('alice'), 'node-a');
  });

  test('claiming an already-taken username (different nodeId) fails with a '
      'clear error', () async {
    await store.claim('alice', 'node-a');

    final result = await store.claim('alice', 'node-b');

    expect(result.success, isFalse);
    expect(result.error, usernameAlreadyTakenError);
    expect(await store.lookup('alice'), 'node-a');
  });

  test('re-claiming your own username is idempotent', () async {
    await store.claim('alice', 'node-a');

    final result = await store.claim('alice', 'node-a');

    expect(result.success, isTrue);
    expect(await store.lookup('alice'), 'node-a');
  });

  test('claiming a second username releases the first, which becomes available '
      'for a different node', () async {
    await store.claim('alice', 'node-a');

    final secondClaim = await store.claim('alicia', 'node-a');
    expect(secondClaim.success, isTrue);

    // The old username is now unowned...
    expect(await store.lookup('alice'), isNull);
    // ...and a genuinely different node can claim it.
    final otherNodeClaim = await store.claim('alice', 'node-b');
    expect(otherNodeClaim.success, isTrue);
    expect(await store.lookup('alice'), 'node-b');
    expect(await store.lookup('alicia'), 'node-a');
  });

  test('an invalid-format username is rejected', () async {
    final result = await store.claim('ab', 'node-a'); // too short

    expect(result.success, isFalse);
    expect(result.error, invalidUsernameFormatError);
    expect(await store.lookup('ab'), isNull);
  });

  test('rejects usernames with characters outside the allowed set', () async {
    final result = await store.claim('not valid!', 'node-a');

    expect(result.success, isFalse);
    expect(result.error, invalidUsernameFormatError);
  });

  test('accepts a username at each length boundary', () async {
    expect((await store.claim('abc', 'node-a')).success, isTrue);
    expect((await store.claim('a' * 32, 'node-a')).success, isTrue);
  });

  test('rejects a username one character over the length boundary', () async {
    final result = await store.claim('a' * 33, 'node-a');
    expect(result.success, isFalse);
    expect(result.error, invalidUsernameFormatError);
  });

  test('persists claims across store instances', () async {
    await store.claim('alice', 'node-a');

    final reloaded = UsernameDirectoryStore(tempDir);
    expect(await reloaded.lookup('alice'), 'node-a');
  });

  test(
    'persists a release (superseded username) across store instances',
    () async {
      await store.claim('alice', 'node-a');
      await store.claim('alicia', 'node-a');

      final reloaded = UsernameDirectoryStore(tempDir);
      expect(await reloaded.lookup('alice'), isNull);
      expect(await reloaded.lookup('alicia'), 'node-a');
    },
  );

  test(
    'two concurrent claims for the same username by different nodeIds '
    'result in exactly one success, not two (regression test for issue #8)',
    () async {
      // Real repro of the reported race: claim()'s load-mutate-save cycle
      // has an await between the load and the save, so without locking,
      // two concurrent claims for the *same* username by two *different*
      // nodeIds can both read the file before either writes it back, both
      // see it as unclaimed, and both report success -- even though only
      // one of them can actually end up owning it. Run many times in one
      // test (rather than once) since a race is exactly the kind of bug
      // that can pass by luck on a single run.
      for (var i = 0; i < 20; i++) {
        final username = 'alice$i';
        final results = await Future.wait([
          store.claim(username, 'node-A'),
          store.claim(username, 'node-B'),
        ]);

        final successes = results.where((r) => r.success).toList();
        expect(
          successes,
          hasLength(1),
          reason:
              'exactly one of the two concurrent claims for "$username" '
              'must succeed',
        );

        final failure = results.firstWhere((r) => !r.success);
        expect(failure.error, usernameAlreadyTakenError);

        // The one that reported success must be the one that actually
        // ends up owning the username -- not last-writer-wins clobbering
        // the reported outcome.
        final winner = successes.single == results[0] ? 'node-A' : 'node-B';
        expect(await store.lookup(username), winner);
      }
    },
  );

  test('many concurrent claims for the same username by the same nodeId all '
      'succeed and never corrupt the persisted file', () async {
    final results = await Future.wait(
      List.generate(10, (_) => store.claim('alice', 'same-node')),
    );

    expect(results.every((r) => r.success), isTrue);
    expect(await store.lookup('alice'), 'same-node');
  });

  // The concurrent-claim invariant is part of the [UsernameDirectory]
  // interface's contract, not just this one implementation's -- cheap to
  // check against every implementation so a future one can't reintroduce
  // this bug. [InMemoryUsernameDirectory]'s claim() has no `await` in its
  // body at all, so it can't interleave with itself by construction; this
  // is a guard against that ceasing to be true, not a fix for anything
  // currently broken there.
  group('every UsernameDirectory implementation honors "exactly one success" '
      'for concurrent same-username claims by different nodeIds', () {
    final implementations = <String, UsernameDirectory Function()>{
      'InMemoryUsernameDirectory': InMemoryUsernameDirectory.new,
      // Reuses the fresh instance the outer setUp() already created for
      // this specific test run.
      'UsernameDirectoryStore': () => store,
    };

    for (final entry in implementations.entries) {
      test(entry.key, () async {
        final directory = entry.value();

        final results = await Future.wait([
          directory.claim('alice', 'node-A'),
          directory.claim('alice', 'node-B'),
        ]);

        expect(results.where((r) => r.success), hasLength(1));
        final winner = results[0].success ? 'node-A' : 'node-B';
        expect(await directory.lookup('alice'), winner);
      });
    }
  });
}
