import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:test/test.dart';

/// A `friends.json` in the exact shape written *before* accounts existed —
/// deliberately hand-written here rather than produced by the current code,
/// so this stays a real fixture of the old on-disk format even if
/// [Friend.toJson] changes again later.
const _legacyFriendsJson = '''
[
  {
    "nodeId": "legacy-node-1",
    "publicKeyBase64": "legacy-key-1",
    "address": "legacy.example:8080",
    "displayName": "Legacy Friend",
    "udpCandidate": "203.0.113.5:41234",
    "relayUrl": "ws://relay.example.com:8090/connect",
    "localNickname": "Bestie"
  },
  {
    "nodeId": "legacy-node-2",
    "publicKeyBase64": "legacy-key-2",
    "address": "legacy2.example:8080",
    "displayName": null,
    "udpCandidate": null,
    "relayUrl": null,
    "localNickname": null
  }
]
''';

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

  void writeRawFriendsFile(String contents) {
    File('${tempDir.path}/friends.json').writeAsStringSync(contents);
  }

  test('starts empty', () async {
    expect(await store.loadAll(), isEmpty);
    expect(await store.findByDeviceNodeId('unknown'), isNull);
    expect(await store.findByAccountId('unknown'), isNull);
    expect(await store.findByAccountOrDeviceId('unknown'), isNull);
  });

  test('adds and finds a friend, persisted across store instances', () async {
    await store.add(
      Friend.devicePinned(
        nodeId: 'abc',
        publicKeyBase64: 'key',
        address: 'host:8080',
        displayName: 'Friend A',
      ),
    );

    final reloaded = FriendStore(tempDir);
    final friend = await reloaded.findByDeviceNodeId('abc');

    expect(friend, isNotNull);
    expect(friend!.primaryDevice?.address, 'host:8080');
    expect(friend.displayName, 'Friend A');
    // A device-pinned friend's synthetic accountId is its own nodeId.
    expect(friend.accountId, 'abc');
    expect(friend.isDevicePinned, isTrue);
  });

  test('persists relayUrl across store instances', () async {
    await store.add(
      Friend.devicePinned(
        nodeId: 'abc',
        publicKeyBase64: 'key',
        address: 'host:8080',
        relayUrl: 'ws://relay.example.com/connect',
      ),
    );

    final reloaded = FriendStore(tempDir);
    final friend = await reloaded.findByDeviceNodeId('abc');

    expect(friend!.primaryDevice?.relayUrl, 'ws://relay.example.com/connect');
  });

  test('relayUrl defaults to null when not provided', () async {
    await store.add(
      Friend.devicePinned(
        nodeId: 'abc',
        publicKeyBase64: 'key',
        address: 'a:1',
      ),
    );

    final friend = await store.findByDeviceNodeId('abc');
    expect(friend!.primaryDevice?.relayUrl, isNull);
  });

  test(
    'adding a friend with the same account replaces the old entry',
    () async {
      await store.add(
        Friend.devicePinned(
          nodeId: 'abc',
          publicKeyBase64: 'old',
          address: 'a:1',
        ),
      );
      await store.add(
        Friend.devicePinned(
          nodeId: 'abc',
          publicKeyBase64: 'new',
          address: 'b:2',
        ),
      );

      final friends = await store.loadAll();
      expect(friends, hasLength(1));
      expect(friends.single.primaryDevice?.publicKeyBase64, 'new');
    },
  );

  test('removes a friend', () async {
    await store.add(
      Friend.devicePinned(
        nodeId: 'abc',
        publicKeyBase64: 'key',
        address: 'a:1',
      ),
    );

    await store.remove('abc');

    expect(await store.findByDeviceNodeId('abc'), isNull);
    expect(await store.loadAll(), isEmpty);
  });

  test('removing an unknown nodeId is a no-op for the friend list', () async {
    await store.remove('does-not-exist'); // does not throw
    expect(await store.loadAll(), isEmpty);
  });

  group('a legacy friends.json written before accounts existed', () {
    test('loads unchanged: accountId == nodeId, exactly one device', () async {
      writeRawFriendsFile(_legacyFriendsJson);

      final friends = await store.loadAll();

      expect(friends, hasLength(2));
      final legacy = friends.first;
      expect(legacy.accountId, 'legacy-node-1');
      expect(legacy.isDevicePinned, isTrue);
      expect(legacy.devices, hasLength(1));
      expect(legacy.devices.single.nodeId, 'legacy-node-1');
      expect(legacy.devices.single.publicKeyBase64, 'legacy-key-1');
      expect(legacy.devices.single.address, 'legacy.example:8080');
      expect(legacy.devices.single.udpCandidate, '203.0.113.5:41234');
      expect(
        legacy.devices.single.relayUrl,
        'ws://relay.example.com:8090/connect',
      );
      expect(legacy.displayName, 'Legacy Friend');
      expect(legacy.localNickname, 'Bestie');
      expect(legacy.devicesRefreshedAt, isNull);
    });

    test('is found by its nodeId through every lookup', () async {
      writeRawFriendsFile(_legacyFriendsJson);

      expect(await store.findByDeviceNodeId('legacy-node-1'), isNotNull);
      expect(await store.findByAccountId('legacy-node-1'), isNotNull);
      expect(await store.findByAccountOrDeviceId('legacy-node-1'), isNotNull);
    });

    test('still exposes the flat legacy fields the app reads', () async {
      writeRawFriendsFile(_legacyFriendsJson);

      final json = (await store.loadAll()).first.toJson();

      expect(json['nodeId'], 'legacy-node-1');
      expect(json['publicKeyBase64'], 'legacy-key-1');
      expect(json['address'], 'legacy.example:8080');
      expect(json['relayUrl'], 'ws://relay.example.com:8090/connect');
      expect(json['localNickname'], 'Bestie');
      // ...alongside the new account view of the same friend.
      expect(json['accountId'], 'legacy-node-1');
      expect(json['devices'], hasLength(1));
    });

    test('survives a rewrite: saving it back and reloading changes nothing '
        'observable', () async {
      writeRawFriendsFile(_legacyFriendsJson);
      final before = (await store.loadAll()).first;

      // Any mutation rewrites the whole file in the new format.
      await store.setLocalNickname('legacy-node-2', 'Second');

      final after = (await FriendStore(tempDir).loadAll()).first;
      expect(after.accountId, before.accountId);
      expect(after.isDevicePinned, isTrue);
      expect(after.devices.single.nodeId, before.devices.single.nodeId);
      expect(
        after.devices.single.publicKeyBase64,
        before.devices.single.publicKeyBase64,
      );
      expect(after.devices.single.address, before.devices.single.address);
      expect(after.localNickname, 'Bestie');
    });
  });

  group('an account-based friend with several devices', () {
    Friend twoDeviceFriend() => Friend(
      accountId: 'account-1',
      devices: [
        const FriendDevice(
          nodeId: 'device-a',
          publicKeyBase64: 'key-a',
          address: 'a.example:8080',
        ),
        const FriendDevice(nodeId: 'device-b', publicKeyBase64: 'key-b'),
      ],
      displayName: 'Account Friend',
    );

    test('is found by its accountId and by either device nodeId', () async {
      await store.add(twoDeviceFriend());

      expect(
        (await store.findByAccountId('account-1'))?.accountId,
        'account-1',
      );
      expect(
        (await store.findByDeviceNodeId('device-a'))?.accountId,
        'account-1',
      );
      expect(
        (await store.findByDeviceNodeId('device-b'))?.accountId,
        'account-1',
      );
      expect(
        (await store.findByAccountOrDeviceId('device-b'))?.accountId,
        'account-1',
      );
      expect(await store.findByDeviceNodeId('account-1'), isNull);
    });

    test('is not device-pinned, and round-trips through the file', () async {
      await store.add(twoDeviceFriend());

      final reloaded = await FriendStore(tempDir).findByAccountId('account-1');

      expect(reloaded!.isDevicePinned, isFalse);
      expect(reloaded.devices, hasLength(2));
      expect(reloaded.deviceFor('device-b')?.publicKeyBase64, 'key-b');
      // The legacy projection prefers the device that actually has an
      // address, since an address-less one is useless to a caller.
      expect(reloaded.primaryDevice?.nodeId, 'device-a');
      expect(reloaded.toJson()['address'], 'a.example:8080');
    });

    test('can be removed by any of its device nodeIds', () async {
      await store.add(twoDeviceFriend());

      await store.remove('device-b');

      expect(await store.loadAll(), isEmpty);
      expect(await store.isRemoved('account-1'), isTrue);
    });

    test('updateDevices replaces the set, keeping locally-known addresses '
        'and dropping devices that are gone', () async {
      await store.add(twoDeviceFriend());

      final updated = await store.updateDevices('account-1', [
        // device-a is still linked -- its locally-learned address must
        // survive, since the account service never knew it.
        const FriendDevice(
          nodeId: 'device-a',
          publicKeyBase64: 'key-a',
          address: 'a.example:8080',
        ),
        const FriendDevice(nodeId: 'device-c', publicKeyBase64: 'key-c'),
      ]);

      expect(updated!.devices.map((d) => d.nodeId), ['device-a', 'device-c']);
      expect(updated.deviceFor('device-a')?.address, 'a.example:8080');
      expect(updated.devicesRefreshedAt, isNotNull);
      expect(await store.findByDeviceNodeId('device-b'), isNull);
    });

    test('updateDevices never creates a friend', () async {
      final updated = await store.updateDevices('never-heard-of-it', [
        const FriendDevice(nodeId: 'x', publicKeyBase64: 'k'),
      ]);

      expect(updated, isNull);
      expect(await store.loadAll(), isEmpty);
    });

    test('a device claimed by one account is pruned from another '
        "account-based friend's stale cache", () async {
      await store.add(twoDeviceFriend());
      await store.add(
        Friend(
          accountId: 'account-2',
          devices: [
            const FriendDevice(nodeId: 'device-z', publicKeyBase64: 'key-z'),
          ],
        ),
      );

      // The account service now says device-z belongs to account-1.
      await store.updateDevices('account-1', [
        const FriendDevice(nodeId: 'device-z', publicKeyBase64: 'key-z'),
      ]);

      expect(
        (await store.findByDeviceNodeId('device-z'))?.accountId,
        'account-1',
      );
      expect((await store.findByAccountId('account-2'))!.devices, isEmpty);
    });

    test('a legacy device-pinned friend is never pruned this way', () async {
      await store.add(
        Friend.devicePinned(
          nodeId: 'legacy-node',
          publicKeyBase64: 'legacy-key',
          address: 'l:1',
        ),
      );
      await store.add(twoDeviceFriend());

      await store.updateDevices('account-1', [
        const FriendDevice(nodeId: 'legacy-node', publicKeyBase64: 'other'),
      ]);

      final legacy = await store.findByAccountId('legacy-node');
      expect(legacy!.devices, hasLength(1));
    });
  });

  group('tombstones', () {
    test('removing a friend records a tombstone', () async {
      await store.add(
        Friend(
          accountId: 'account-1',
          devices: [
            const FriendDevice(nodeId: 'device-a', publicKeyBase64: 'key-a'),
          ],
        ),
      );

      await store.remove('account-1');

      expect(await store.isRemoved('account-1'), isTrue);
      final tombstones = await store.loadTombstones();
      expect(tombstones.single.accountId, 'account-1');
      expect(tombstones.single.removedAt.isUtc, isTrue);
      // Persisted, not just in memory.
      expect(await FriendStore(tempDir).isRemoved('account-1'), isTrue);
    });

    test('a tombstoned account cannot be resurrected by updateDevices, even '
        'though the account service still lists its devices', () async {
      await store.add(
        Friend(
          accountId: 'account-1',
          devices: [
            const FriendDevice(nodeId: 'device-a', publicKeyBase64: 'key-a'),
          ],
        ),
      );
      await store.remove('account-1');

      final updated = await store.updateDevices('account-1', [
        const FriendDevice(nodeId: 'device-a', publicKeyBase64: 'key-a'),
      ]);

      expect(updated, isNull);
      expect(await store.loadAll(), isEmpty);
      expect(await store.findByDeviceNodeId('device-a'), isNull);
    });

    test('removing an account this node has never heard of still tombstones '
        'it, so learning about it later cannot add it', () async {
      await store.remove('account-not-yet-known');

      expect(await store.isRemoved('account-not-yet-known'), isTrue);
      expect(
        await store.updateDevices('account-not-yet-known', [
          const FriendDevice(nodeId: 'd', publicKeyBase64: 'k'),
        ]),
        isNull,
      );
    });

    test(
      'explicitly re-adding a removed friend clears their tombstone',
      () async {
        await store.add(
          Friend(
            accountId: 'account-1',
            devices: [
              const FriendDevice(nodeId: 'device-a', publicKeyBase64: 'key-a'),
            ],
          ),
        );
        await store.remove('account-1');

        await store.add(
          Friend(
            accountId: 'account-1',
            devices: [
              const FriendDevice(nodeId: 'device-a', publicKeyBase64: 'key-a'),
            ],
          ),
        );

        expect(await store.isRemoved('account-1'), isFalse);
        expect(await store.loadTombstones(), isEmpty);
        expect(
          await store.updateDevices('account-1', [
            const FriendDevice(nodeId: 'device-a', publicKeyBase64: 'key-a'),
            const FriendDevice(nodeId: 'device-b', publicKeyBase64: 'key-b'),
          ]),
          isNotNull,
        );
      },
    );

    test('the tombstone file is valid JSON on disk', () async {
      await store.remove('account-1');

      final raw = File(
        '${tempDir.path}/removed_friends.json',
      ).readAsStringSync();
      final parsed = jsonDecode(raw) as List<dynamic>;
      expect((parsed.single as Map<String, dynamic>)['accountId'], 'account-1');
    });
  });

  group('concurrent mutations (the resurrection race)', () {
    test(
      'a remove landing inside an in-flight updateDevices is not undone',
      () async {
        await store.add(
          Friend(
            accountId: 'account-victim',
            devices: const [
              FriendDevice(nodeId: 'victim-device', publicKeyBase64: 'k-v'),
            ],
          ),
        );
        await store.add(
          Friend(
            accountId: 'account-other',
            devices: const [
              FriendDevice(nodeId: 'other-device', publicKeyBase64: 'k-o'),
            ],
          ),
        );

        // Both are load-mutate-save cycles over the same file. Started
        // together and awaited together, they interleave: before the store
        // serialized its mutations, the refresh wrote back the whole list it
        // had loaded *before* the removal, silently restoring the removed
        // friend -- complete with their device keys, so their signed
        // requests verified again, permanently. The tombstone was written
        // but nothing on the read path consults it.
        final refresh = store.updateDevices('account-other', const [
          FriendDevice(nodeId: 'other-device-2', publicKeyBase64: 'k-o2'),
        ]);
        final removal = store.remove('account-victim');
        await Future.wait<void>([refresh, removal]);

        expect(await store.findByAccountId('account-victim'), isNull);
        expect(await store.findByDeviceNodeId('victim-device'), isNull);
        expect(await store.isRemoved('account-victim'), isTrue);
        // ...and the other friend's refresh still landed.
        expect(
          (await store.findByAccountId('account-other'))!.devices.single.nodeId,
          'other-device-2',
        );
      },
    );

    test(
      'the same holds in the other order, and across a fresh store',
      () async {
        await store.add(
          Friend(
            accountId: 'account-victim',
            devices: const [
              FriendDevice(nodeId: 'victim-device', publicKeyBase64: 'k-v'),
            ],
          ),
        );

        final removal = store.remove('victim-device');
        final refresh = store.updateDevices('account-victim', const [
          FriendDevice(nodeId: 'victim-device', publicKeyBase64: 'k-v'),
          FriendDevice(nodeId: 'victim-device-2', publicKeyBase64: 'k-v2'),
        ]);
        await Future.wait<void>([removal, refresh]);

        final reopened = FriendStore(tempDir);
        expect(await reopened.loadAll(), isEmpty);
        expect(await reopened.findByDeviceNodeId('victim-device-2'), isNull);
      },
    );
  });

  group('add supersedes an entry for the same device', () {
    test('an account-based re-pair replaces the legacy device-pinned entry '
        'for that same device', () async {
      // The headline migration path: someone already paired the old way
      // signs up for an account and pairs again. Deduping on accountId
      // alone left both entries in place -- two trusted friends for one
      // human and one device -- so removing the account one still left the
      // device fully trusted through the legacy one.
      await store.add(
        Friend.devicePinned(
          nodeId: 'bob-device',
          publicKeyBase64: 'bob-key',
          address: 'bob:8080',
        ),
      );
      await store.add(
        Friend(
          accountId: 'account-bob',
          devices: const [
            FriendDevice(
              nodeId: 'bob-device',
              publicKeyBase64: 'bob-key',
              address: 'bob:8080',
            ),
          ],
        ),
      );

      expect(await store.loadAll(), hasLength(1));
      expect((await store.loadAll()).single.accountId, 'account-bob');

      await store.remove('account-bob');
      expect(await store.findByDeviceNodeId('bob-device'), isNull);
      expect(await store.loadAll(), isEmpty);
    });

    test('an unrelated friend sharing no device is left alone', () async {
      await store.add(
        Friend.devicePinned(
          nodeId: 'carol-device',
          publicKeyBase64: 'carol-key',
          address: 'carol:8080',
        ),
      );
      await store.add(
        Friend(
          accountId: 'account-bob',
          devices: const [
            FriendDevice(nodeId: 'bob-device', publicKeyBase64: 'bob-key'),
          ],
        ),
      );

      expect(await store.loadAll(), hasLength(2));
    });
  });

  group('isRemovedDevice', () {
    test('a removed account\'s devices are refusable without knowing the '
        'accountId', () async {
      await store.add(
        Friend(
          accountId: 'account-bob',
          devices: const [
            FriendDevice(nodeId: 'bob-phone', publicKeyBase64: 'k1'),
            FriendDevice(nodeId: 'bob-desktop', publicKeyBase64: 'k2'),
          ],
        ),
      );
      await store.remove('account-bob');

      // The point of the field: resolving 'bob-phone' to 'account-bob' is
      // exactly the account-service call this lets the caller skip.
      expect(await store.isRemovedDevice('bob-phone'), isTrue);
      expect(await store.isRemovedDevice('bob-desktop'), isTrue);
      expect(await store.isRemovedDevice('someone-else'), isFalse);
    });

    test('removing an already-removed account does not wipe the device ids '
        'recorded the first time', () async {
      await store.add(
        Friend(
          accountId: 'account-bob',
          devices: const [
            FriendDevice(nodeId: 'bob-phone', publicKeyBase64: 'k1'),
          ],
        ),
      );
      await store.remove('account-bob');
      // The second call finds no friend left, so it has no devices of its
      // own to record. It must carry forward the ones already tombstoned
      // rather than replacing them with an empty list -- otherwise a
      // duplicate DELETE would quietly restore the per-request lookup this
      // field exists to avoid.
      await store.remove('account-bob');

      expect(await store.isRemoved('account-bob'), isTrue);
      expect(await store.isRemovedDevice('bob-phone'), isTrue);
    });

    test('re-adding clears the account tombstone, and with it the device '
        'refusals', () async {
      await store.add(
        Friend(
          accountId: 'account-bob',
          devices: const [
            FriendDevice(nodeId: 'bob-phone', publicKeyBase64: 'k1'),
          ],
        ),
      );
      await store.remove('account-bob');
      expect(await store.isRemovedDevice('bob-phone'), isTrue);

      await store.add(
        Friend(
          accountId: 'account-bob',
          devices: const [
            FriendDevice(nodeId: 'bob-phone', publicKeyBase64: 'k1'),
          ],
        ),
      );

      expect(await store.isRemoved('account-bob'), isFalse);
      expect(await store.isRemovedDevice('bob-phone'), isFalse);
    });
  });

  group('setLocalNickname', () {
    test('sets a local nickname and persists it', () async {
      await store.add(
        Friend.devicePinned(
          nodeId: 'abc',
          publicKeyBase64: 'key',
          address: 'host:8080',
          displayName: 'Friend A',
        ),
      );

      final updated = await store.setLocalNickname('abc', 'Bestie');

      expect(updated?.localNickname, 'Bestie');

      final reloaded = FriendStore(tempDir);
      final friend = await reloaded.findByDeviceNodeId('abc');
      expect(friend?.localNickname, 'Bestie');
    });

    test('does not clobber the friend\'s other fields', () async {
      await store.add(
        Friend.devicePinned(
          nodeId: 'abc',
          publicKeyBase64: 'key',
          address: 'host:8080',
          displayName: 'Friend A',
          udpCandidate: '203.0.113.5:41234',
          relayUrl: 'ws://relay.example.com/connect',
        ),
      );

      final updated = await store.setLocalNickname('abc', 'Bestie');

      expect(updated?.primaryDevice?.publicKeyBase64, 'key');
      expect(updated?.primaryDevice?.address, 'host:8080');
      expect(updated?.displayName, 'Friend A');
      expect(updated?.primaryDevice?.udpCandidate, '203.0.113.5:41234');
      expect(
        updated?.primaryDevice?.relayUrl,
        'ws://relay.example.com/connect',
      );
    });

    test('clearing it back to null persists', () async {
      await store.add(
        Friend.devicePinned(
          nodeId: 'abc',
          publicKeyBase64: 'key',
          address: 'host:8080',
          localNickname: 'Bestie',
        ),
      );

      final updated = await store.setLocalNickname('abc', null);

      expect(updated?.localNickname, isNull);
      final friend = await store.findByDeviceNodeId('abc');
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

  group('addFromAccountService (the sync-driven add)', () {
    test('adds a friend account this node has never seen', () async {
      final added = await store.addFromAccountService(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
          ],
          displayName: 'alice',
        ),
      );

      expect(added, isNotNull);
      final stored = await store.findByAccountId('account-alice');
      expect(stored!.displayName, 'alice');
      expect(stored.devices.single.nodeId, 'alice-phone');
    });

    test('refuses a tombstoned account -- and, unlike add(), leaves the '
        'tombstone in place', () async {
      await store.add(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
          ],
        ),
      );
      await store.remove('account-alice');

      final added = await store.addFromAccountService(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
          ],
        ),
      );

      expect(added, isNull);
      expect(await store.loadAll(), isEmpty);
      expect(
        await store.isRemoved('account-alice'),
        isTrue,
        reason:
            'the tombstone was cleared, so the *next* sync would resurrect '
            'her -- exactly what add() is allowed to do and this is not',
      );
    });

    test('a remove landing inside an in-flight addFromAccountService still '
        'sticks -- the check is inside the lock, not the caller', () async {
      // The exact race a caller-side isRemoved() + add() would lose: the
      // sync decides to add, the user removes, the add lands last.
      for (var i = 0; i < 20; i++) {
        final fresh = Directory.systemTemp.createTempSync(
          'musicat_friend_store_race_',
        );
        final raced = FriendStore(fresh);
        await raced.add(
          const Friend(
            accountId: 'account-alice',
            devices: [
              FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
            ],
          ),
        );
        final removal = raced.remove('account-alice');
        final adding = raced.addFromAccountService(
          const Friend(
            accountId: 'account-alice',
            devices: [
              FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
              FriendDevice(nodeId: 'alice-desktop', publicKeyBase64: 'k-a2'),
            ],
          ),
        );
        await Future.wait<Object?>([removal, adding]);

        expect(await raced.isRemoved('account-alice'), isTrue);
        expect(await raced.findByAccountId('account-alice'), isNull);
        expect(await raced.findByDeviceNodeId('alice-desktop'), isNull);
        fresh.deleteSync(recursive: true);
      }
    });

    test('refuses to displace a device-pinned friend that already holds one '
        'of those devices', () async {
      // Alice was paired out-of-band, so this node has the only address
      // anybody has for her. add() would supersede that entry; this must
      // not, because the replacement would arrive address-less.
      await store.add(
        Friend.devicePinned(
          nodeId: 'alice-phone',
          publicKeyBase64: 'k-a',
          address: 'alice.example:8080',
        ),
      );

      final added = await store.addFromAccountService(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
          ],
        ),
      );

      expect(added, isNull);
      final friends = await store.loadAll();
      expect(friends, hasLength(1));
      expect(friends.single.isDevicePinned, isTrue);
      expect(friends.single.devices.single.address, 'alice.example:8080');
    });

    test('refuses to overwrite an existing entry for the same account, so a '
        'locally-learned address is never discarded', () async {
      await store.add(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(
              nodeId: 'alice-phone',
              publicKeyBase64: 'k-a',
              address: 'alice.example:8080',
            ),
          ],
        ),
      );

      final added = await store.addFromAccountService(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
          ],
        ),
      );

      expect(added, isNull);
      expect(
        (await store.findByAccountId('account-alice'))!.devices.single.address,
        'alice.example:8080',
      );
    });

    test('prunes the added devices from other *account-based* friends, so '
        'findByDeviceNodeId stays unambiguous', () async {
      // A device that moved between accounts, with a stale cache still
      // listing it under the old one.
      await store.add(
        const Friend(
          accountId: 'account-old',
          devices: [
            FriendDevice(nodeId: 'shared-device', publicKeyBase64: 'k-s'),
            FriendDevice(nodeId: 'old-only', publicKeyBase64: 'k-o'),
          ],
        ),
      );

      await store.addFromAccountService(
        const Friend(
          accountId: 'account-new',
          devices: [
            FriendDevice(nodeId: 'shared-device', publicKeyBase64: 'k-s'),
          ],
        ),
      );

      expect(
        (await store.findByDeviceNodeId('shared-device'))!.accountId,
        'account-new',
      );
      expect(
        (await store.findByAccountId(
          'account-old',
        ))!.devices.map((d) => d.nodeId),
        ['old-only'],
      );
    });
  });

  group('confirmedByAccountService (who established this friendship)', () {
    const alice = Friend(
      accountId: 'account-alice',
      devices: [FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a')],
    );

    test('add() clears it, whatever the caller passed -- pairing is local '
        'trust', () async {
      await store.add(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
          ],
          // A caller getting this wrong must not be able to make a paired
          // friend look sync-removable.
          confirmedByAccountService: true,
        ),
      );

      expect(
        (await store.findByAccountId(
          'account-alice',
        ))!.confirmedByAccountService,
        isFalse,
      );
    });

    test('addFromAccountService() sets it', () async {
      await store.addFromAccountService(alice);

      expect(
        (await store.findByAccountId(
          'account-alice',
        ))!.confirmedByAccountService,
        isTrue,
      );
    });

    test('updateDevices() promotes a friend the account service has now '
        'vouched for -- so an entry written before this field existed does '
        'not stay un-removable forever', () async {
      await store.add(alice);
      expect(
        (await store.findByAccountId(
          'account-alice',
        ))!.confirmedByAccountService,
        isFalse,
      );

      await store.updateDevices('account-alice', const [
        FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
      ]);

      expect(
        (await store.findByAccountId(
          'account-alice',
        ))!.confirmedByAccountService,
        isTrue,
      );
    });

    test('setLocalNickname() preserves it', () async {
      await store.addFromAccountService(alice);

      await store.setLocalNickname('account-alice', 'Bestie');

      expect(
        (await store.findByAccountId(
          'account-alice',
        ))!.confirmedByAccountService,
        isTrue,
      );
    });

    test('round-trips through the file, and defaults to false for an entry '
        'written before it existed', () async {
      await store.addFromAccountService(alice);
      expect(
        (await FriendStore(
          tempDir,
        ).findByAccountId('account-alice'))!.confirmedByAccountService,
        isTrue,
      );

      // The pre-this-round shape: the same entry with the key simply absent.
      final file = File('${tempDir.path}/friends.json');
      final json = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      (json.single as Map<String, dynamic>).remove('confirmedByAccountService');
      file.writeAsStringSync(jsonEncode(json));

      expect(
        (await FriendStore(
          tempDir,
        ).findByAccountId('account-alice'))!.confirmedByAccountService,
        isFalse,
        reason:
            'an old entry must default to the safe answer -- unconfirmed, and '
            'therefore never deleted by a sync until one confirms it',
      );
    });
  });

  group('removeFromAccountService (the other side unfriended us)', () {
    Future<void> addConfirmed() => store.addFromAccountService(
      const Friend(
        accountId: 'account-alice',
        devices: [FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a')],
        displayName: 'alice',
      ),
    );

    test('removes a confirmed account friend, keys and all', () async {
      await addConfirmed();

      expect(await store.removeFromAccountService('account-alice'), isTrue);

      expect(await store.findByAccountId('account-alice'), isNull);
      expect(
        await store.findByDeviceNodeId('alice-phone'),
        isNull,
        reason:
            "their cached device keys have to go with them, or their signed "
            'requests keep verifying',
      );
    });

    test('writes NO tombstone -- this is not the user\'s own decision, and '
        'tombstoning it would make a later re-friend silently fail', () async {
      await addConfirmed();

      await store.removeFromAccountService('account-alice');

      expect(await store.loadTombstones(), isEmpty);
      expect(await store.isRemoved('account-alice'), isFalse);
      expect(await store.isRemovedDevice('alice-phone'), isFalse);

      // ...and the proof of why that matters: befriending again on the
      // account service takes effect here, with no local action needed.
      final again = await store.addFromAccountService(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
          ],
        ),
      );
      expect(again, isNotNull);
      expect(await store.findByAccountId('account-alice'), isNotNull);
    });

    test("the deliberate kind still tombstones -- the asymmetry, side by "
        'side', () async {
      await addConfirmed();

      await store.remove('account-alice');

      expect(await store.isRemoved('account-alice'), isTrue);
      expect(
        await store.addFromAccountService(
          const Friend(
            accountId: 'account-alice',
            devices: [
              FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
            ],
          ),
        ),
        isNull,
      );
    });

    test('refuses a device-pinned friend -- out-of-band trust is invisible '
        'to the account service, so its silence means nothing', () async {
      await store.add(
        Friend.devicePinned(
          nodeId: 'pinned-node',
          publicKeyBase64: 'k-p',
          address: 'pinned.example:8080',
        ),
      );

      expect(await store.removeFromAccountService('pinned-node'), isFalse);

      final kept = await store.findByAccountId('pinned-node');
      expect(kept, isNotNull);
      expect(kept!.devices.single.address, 'pinned.example:8080');
    });

    test('refuses an account friend the account service never vouched for -- '
        'two people who paired out-of-band while both logged in', () async {
      // Exactly what `POST /api/v1/federation/friends` writes when the
      // caller claims an accountId and the account service confirms the
      // *device* belongs to it (ADR 0049). They were never friends *on* that
      // service, so they never appear in its list.
      await store.add(
        const Friend(
          accountId: 'account-alice',
          devices: [
            FriendDevice(
              nodeId: 'alice-phone',
              publicKeyBase64: 'k-a',
              address: 'alice.example:8080',
            ),
          ],
          localNickname: 'my label',
        ),
      );

      expect(await store.removeFromAccountService('account-alice'), isFalse);

      final kept = await store.findByAccountId('account-alice');
      expect(kept, isNotNull);
      expect(kept!.devices.single.address, 'alice.example:8080');
      expect(kept.localNickname, 'my label');
    });

    test('is a no-op for an unknown account', () async {
      expect(await store.removeFromAccountService('nobody'), isFalse);
      expect(await store.loadTombstones(), isEmpty);
    });

    test(
      'addresses accounts only, never a device nodeId -- one account\'s '
      'stale cached device must not be able to drop a different friend',
      () async {
        await addConfirmed();

        expect(await store.removeFromAccountService('alice-phone'), isFalse);
        expect(await store.findByAccountId('account-alice'), isNotNull);
      },
    );

    test('a concurrent add() wins: the entry it turns into local trust is '
        'never dropped by an in-flight sync removal', () async {
      for (var i = 0; i < 20; i++) {
        final fresh = Directory.systemTemp.createTempSync(
          'musicat_friend_store_revoke_race_',
        );
        addTearDown(() => fresh.deleteSync(recursive: true));
        final raced = FriendStore(fresh);
        await raced.addFromAccountService(
          const Friend(
            accountId: 'account-alice',
            devices: [
              FriendDevice(nodeId: 'alice-phone', publicKeyBase64: 'k-a'),
            ],
          ),
        );

        // The user re-pairs at the same moment a sync decides she is gone.
        final pairing = raced.add(
          const Friend(
            accountId: 'account-alice',
            devices: [
              FriendDevice(
                nodeId: 'alice-phone',
                publicKeyBase64: 'k-a',
                address: 'alice.example:8080',
              ),
            ],
          ),
        );
        final removing = raced.removeFromAccountService('account-alice');
        await Future.wait<Object?>([pairing, removing]);

        // Either order is fine as long as it is *consistent*: if the pairing
        // landed last the friend is there as local trust, and if it landed
        // first the removal saw a confirmed entry and dropped it. What must
        // never happen is a surviving entry that is still marked confirmed
        // while carrying the paired address.
        final alice = await raced.findByAccountId('account-alice');
        if (alice != null) {
          expect(alice.confirmedByAccountService, isFalse);
          expect(alice.devices.single.address, 'alice.example:8080');
        }
      }
    });
  });
}
