import 'dart:io';

import 'package:musicat_server/src/sharing/shared_track.dart';
import 'package:musicat_server/src/sharing/shared_track_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SharedTrackStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'musicat_shared_track_store_',
    );
    store = SharedTrackStore(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  const trackSharedWithOneFriend = SharedTrack(
    id: 't1',
    filePath: '/music/a.flac',
    title: 'One More Time',
    artist: 'Daft Punk',
    visibility: FriendVisibility('friend-1'),
  );

  const trackSharedWithAllFriends = SharedTrack(
    id: 't2',
    filePath: '/music/b.flac',
    title: 'Around the World',
    artist: 'Daft Punk',
    visibility: AllFriendsVisibility(),
  );

  test('starts empty', () async {
    expect(await store.loadAll(), isEmpty);
    expect(await store.findById('t1'), isNull);
  });

  test('adds and finds a track, persisted across store instances', () async {
    await store.add(trackSharedWithOneFriend);

    final reloaded = SharedTrackStore(tempDir);
    final track = await reloaded.findById('t1');

    expect(track, isNotNull);
    expect(track!.title, 'One More Time');
    expect(track.visibility, isA<FriendVisibility>());
    expect((track.visibility as FriendVisibility).nodeId, 'friend-1');
  });

  test('adding a track with the same id replaces the old entry', () async {
    await store.add(trackSharedWithOneFriend);
    await store.add(
      const SharedTrack(
        id: 't1',
        filePath: '/music/a.flac',
        title: 'Retitled',
        artist: 'Daft Punk',
        visibility: AllFriendsVisibility(),
      ),
    );

    final tracks = await store.loadAll();
    expect(tracks, hasLength(1));
    expect(tracks.single.title, 'Retitled');
  });

  test('removes a track', () async {
    await store.add(trackSharedWithOneFriend);
    await store.remove('t1');
    expect(await store.findById('t1'), isNull);
  });

  group('visibleTo', () {
    test('a friend-specific track is visible only to that friend', () async {
      await store.add(trackSharedWithOneFriend);

      expect(await store.visibleTo('friend-1'), hasLength(1));
      expect(await store.visibleTo('someone-else'), isEmpty);
    });

    test('an all-friends track is visible to any requester', () async {
      await store.add(trackSharedWithAllFriends);

      expect(await store.visibleTo('friend-1'), hasLength(1));
      expect(
        await store.visibleTo('a-completely-different-friend'),
        hasLength(1),
      );
    });

    test('mixes both visibility kinds correctly', () async {
      await store.add(trackSharedWithOneFriend);
      await store.add(trackSharedWithAllFriends);

      final visibleToFriend1 = await store.visibleTo('friend-1');
      expect(visibleToFriend1.map((t) => t.id), {'t1', 't2'});

      final visibleToOther = await store.visibleTo('friend-2');
      expect(visibleToOther.map((t) => t.id), {'t2'});
    });
  });
}
