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
}
