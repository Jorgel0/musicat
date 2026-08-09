import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/database/app_database.dart';
import 'package:musicat/features/library/data/library_repository_drift.dart';
import 'package:musicat/features/library/domain/track.dart';
import 'package:musicat/features/playlists/data/playlist_repository_drift.dart';

void main() {
  late AppDatabase db;
  late DriftPlaylistRepository playlists;
  late DriftLibraryRepository library;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    playlists = DriftPlaylistRepository(db);
    library = DriftLibraryRepository(db);
  });

  tearDown(() => db.close());

  Future<int> seedTrack(String title) async {
    await library.upsertTrack(
      filePath: '/music/$title.mp3',
      title: title,
      artist: 'An Artist',
      album: 'An Album',
      source: TrackSource.local,
    );
    final tracks = await library.watchAllTracks().first;
    return tracks.firstWhere((t) => t.title == title).id;
  }

  test('createPlaylist then watchAllPlaylists emits it', () async {
    await playlists.createPlaylist('Road trip');

    final result = await playlists.watchAllPlaylists().first;

    expect(result, hasLength(1));
    expect(result.single.name, 'Road trip');
  });

  test('addTrack keeps tracks in the order they were added', () async {
    final playlistId = await playlists.createPlaylist('Road trip');
    final trackA = await seedTrack('Song A');
    final trackB = await seedTrack('Song B');

    await playlists.addTrack(playlistId, trackA);
    await playlists.addTrack(playlistId, trackB);

    final tracks = await playlists.watchPlaylistTracks(playlistId).first;

    expect(tracks.map((t) => t.title), ['Song A', 'Song B']);
  });

  test('reorderTrack moves a track to its new position', () async {
    final playlistId = await playlists.createPlaylist('Road trip');
    final trackA = await seedTrack('Song A');
    final trackB = await seedTrack('Song B');
    final trackC = await seedTrack('Song C');
    await playlists.addTrack(playlistId, trackA);
    await playlists.addTrack(playlistId, trackB);
    await playlists.addTrack(playlistId, trackC);

    // Move "Song A" (index 0) to the end (index 2).
    await playlists.reorderTrack(playlistId, 0, 2);

    final tracks = await playlists.watchPlaylistTracks(playlistId).first;

    expect(tracks.map((t) => t.title), ['Song B', 'Song C', 'Song A']);
  });

  test('removeTrack removes only the requested track', () async {
    final playlistId = await playlists.createPlaylist('Road trip');
    final trackA = await seedTrack('Song A');
    final trackB = await seedTrack('Song B');
    await playlists.addTrack(playlistId, trackA);
    await playlists.addTrack(playlistId, trackB);

    await playlists.removeTrack(playlistId, trackA);

    final tracks = await playlists.watchPlaylistTracks(playlistId).first;

    expect(tracks.map((t) => t.title), ['Song B']);
  });

  test('renamePlaylist updates the name', () async {
    final playlistId = await playlists.createPlaylist('Old name');

    await playlists.renamePlaylist(playlistId, 'New name');

    final playlist = await playlists.watchPlaylist(playlistId).first;

    expect(playlist?.name, 'New name');
  });

  test('deletePlaylist removes it and its track entries', () async {
    final playlistId = await playlists.createPlaylist('Road trip');
    final trackA = await seedTrack('Song A');
    await playlists.addTrack(playlistId, trackA);

    await playlists.deletePlaylist(playlistId);

    final all = await playlists.watchAllPlaylists().first;
    final tracks = await playlists.watchPlaylistTracks(playlistId).first;

    expect(all, isEmpty);
    expect(tracks, isEmpty);
  });
}
