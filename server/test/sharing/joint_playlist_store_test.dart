import 'dart:io';

import 'package:musicat_server/src/sharing/joint_playlist.dart';
import 'package:musicat_server/src/sharing/joint_playlist_store.dart';
import 'package:musicat_server/src/sharing/playlist_item.dart';
import 'package:test/test.dart';

PlaylistItem _item(String id, {DateTime? addedAt}) => PlaylistItem(
  id: id,
  title: 'Track $id',
  artist: 'Someone',
  ownerNodeId: 'owner',
  sharedTrackId: 'shared-$id',
  addedAt: addedAt ?? DateTime.utc(2026, 1, 1),
);

void main() {
  late Directory tempDir;
  late JointPlaylistStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('musicat_joint_playlist_');
    store = JointPlaylistStore(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('starts empty', () async {
    expect(await store.loadAll(), isEmpty);
    expect(await store.findById('p1'), isNull);
  });

  test(
    'saves and finds a playlist, persisted across store instances',
    () async {
      final playlist = JointPlaylist(
        id: 'p1',
        name: 'Road trip',
        participantNodeIds: const ['friend-1'],
        items: [_item('i1')],
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      await store.save(playlist);

      final reloaded = JointPlaylistStore(tempDir);
      final found = await reloaded.findById('p1');

      expect(found?.name, 'Road trip');
      expect(found?.items, hasLength(1));
    },
  );

  test('removes a playlist', () async {
    await store.save(
      JointPlaylist(
        id: 'p1',
        name: 'x',
        participantNodeIds: const ['friend-1'],
        items: const [],
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await store.remove('p1');
    expect(await store.findById('p1'), isNull);
  });

  group('mergeRemote', () {
    test('adopts a playlist this node has never seen before', () async {
      final remote = JointPlaylist(
        id: 'p1',
        name: 'From a friend',
        participantNodeIds: const ['friend-1'],
        items: [_item('i1')],
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      final merged = await store.mergeRemote(remote);

      expect(merged.items, hasLength(1));
      expect(await store.findById('p1'), isNotNull);
    });

    test(
      'unions items from both sides rather than replacing wholesale',
      () async {
        await store.save(
          JointPlaylist(
            id: 'p1',
            name: 'Road trip',
            participantNodeIds: const ['friend-1'],
            items: [_item('local-only')],
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );

        final remote = JointPlaylist(
          id: 'p1',
          name: 'Road trip',
          participantNodeIds: const ['friend-1'],
          items: [_item('remote-only')],
          updatedAt: DateTime.utc(2026, 1, 2),
        );

        final merged = await store.mergeRemote(remote);

        // Neither side's concurrent addition is lost -- the whole point of
        // a union merge over naive whole-object last-write-wins.
        expect(merged.items.map((i) => i.id), {'local-only', 'remote-only'});
      },
    );

    test('does not duplicate an item both sides already agree on', () async {
      await store.save(
        JointPlaylist(
          id: 'p1',
          name: 'x',
          participantNodeIds: const ['friend-1'],
          items: [_item('shared-item')],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      final merged = await store.mergeRemote(
        JointPlaylist(
          id: 'p1',
          name: 'x',
          participantNodeIds: const ['friend-1'],
          items: [_item('shared-item')],
          updatedAt: DateTime.utc(2026, 1, 2),
        ),
      );

      expect(merged.items, hasLength(1));
    });

    test('updatedAt becomes whichever side is more recent', () async {
      await store.save(
        JointPlaylist(
          id: 'p1',
          name: 'x',
          participantNodeIds: const ['friend-1'],
          items: const [],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      final olderRemote = JointPlaylist(
        id: 'p1',
        name: 'x',
        participantNodeIds: const ['friend-1'],
        items: const [],
        updatedAt: DateTime.utc(2025, 1, 1),
      );
      final merged = await store.mergeRemote(olderRemote);

      expect(merged.updatedAt, DateTime.utc(2026, 1, 1));
    });
  });
}
