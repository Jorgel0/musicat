import 'dart:io';

import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late FriendStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('musicat_friend_store_test_');
    store = FriendStore(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('starts empty', () async {
    expect(await store.loadAll(), isEmpty);
    expect(await store.findByNodeId('unknown'), isNull);
  });

  test('adds and finds a friend, persisted across store instances', () async {
    await store.add(
      const Friend(
        nodeId: 'abc',
        publicKeyBase64: 'key',
        address: 'host:8080',
        displayName: 'Friend A',
      ),
    );

    final reloaded = FriendStore(tempDir);
    final friend = await reloaded.findByNodeId('abc');

    expect(friend, isNotNull);
    expect(friend!.address, 'host:8080');
    expect(friend.displayName, 'Friend A');
  });

  test('persists relayUrl across store instances', () async {
    await store.add(
      const Friend(
        nodeId: 'abc',
        publicKeyBase64: 'key',
        address: 'host:8080',
        relayUrl: 'ws://relay.example.com/connect',
      ),
    );

    final reloaded = FriendStore(tempDir);
    final friend = await reloaded.findByNodeId('abc');

    expect(friend!.relayUrl, 'ws://relay.example.com/connect');
  });

  test('relayUrl defaults to null when not provided', () async {
    await store.add(
      const Friend(nodeId: 'abc', publicKeyBase64: 'key', address: 'a:1'),
    );

    final friend = await store.findByNodeId('abc');
    expect(friend!.relayUrl, isNull);
  });

  test('adding a friend with the same nodeId replaces the old entry', () async {
    await store.add(
      const Friend(nodeId: 'abc', publicKeyBase64: 'old', address: 'a:1'),
    );
    await store.add(
      const Friend(nodeId: 'abc', publicKeyBase64: 'new', address: 'b:2'),
    );

    final friends = await store.loadAll();
    expect(friends, hasLength(1));
    expect(friends.single.publicKeyBase64, 'new');
  });

  test('removes a friend', () async {
    await store.add(
      const Friend(nodeId: 'abc', publicKeyBase64: 'key', address: 'a:1'),
    );

    await store.remove('abc');

    expect(await store.findByNodeId('abc'), isNull);
    expect(await store.loadAll(), isEmpty);
  });

  test('removing an unknown nodeId is a no-op', () async {
    await store.remove('does-not-exist'); // does not throw
    expect(await store.loadAll(), isEmpty);
  });

  group('setLocalNickname', () {
    test('sets a local nickname and persists it', () async {
      await store.add(
        const Friend(
          nodeId: 'abc',
          publicKeyBase64: 'key',
          address: 'host:8080',
          displayName: 'Friend A',
        ),
      );

      final updated = await store.setLocalNickname('abc', 'Bestie');

      expect(updated?.localNickname, 'Bestie');

      final reloaded = FriendStore(tempDir);
      final friend = await reloaded.findByNodeId('abc');
      expect(friend?.localNickname, 'Bestie');
    });

    test('does not clobber the friend\'s other fields', () async {
      await store.add(
        const Friend(
          nodeId: 'abc',
          publicKeyBase64: 'key',
          address: 'host:8080',
          displayName: 'Friend A',
          udpCandidate: '203.0.113.5:41234',
          relayUrl: 'ws://relay.example.com/connect',
        ),
      );

      final updated = await store.setLocalNickname('abc', 'Bestie');

      expect(updated?.publicKeyBase64, 'key');
      expect(updated?.address, 'host:8080');
      expect(updated?.displayName, 'Friend A');
      expect(updated?.udpCandidate, '203.0.113.5:41234');
      expect(updated?.relayUrl, 'ws://relay.example.com/connect');
    });

    test('clearing it back to null persists', () async {
      await store.add(
        const Friend(
          nodeId: 'abc',
          publicKeyBase64: 'key',
          address: 'host:8080',
          localNickname: 'Bestie',
        ),
      );

      final updated = await store.setLocalNickname('abc', null);

      expect(updated?.localNickname, isNull);
      final friend = await store.findByNodeId('abc');
      expect(friend?.localNickname, isNull);
    });

    test(
      'returns null for an unknown nodeId, without creating anything',
      () async {
        final updated = await store.setLocalNickname('does-not-exist', 'x');

        expect(updated, isNull);
        expect(await store.loadAll(), isEmpty);
      },
    );
  });
}
