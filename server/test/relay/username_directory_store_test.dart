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
}
