import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/database/app_database.dart';
import 'package:musicat/features/library/data/library_repository_drift.dart';
import 'package:musicat/features/library/domain/track.dart';

void main() {
  late AppDatabase db;
  late DriftLibraryRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftLibraryRepository(db);
  });

  tearDown(() => db.close());

  test('upsertTrack then watchAllTracks emits the inserted track', () async {
    await repository.upsertTrack(
      filePath: '/music/song.mp3',
      title: 'A Song',
      artist: 'An Artist',
      album: 'An Album',
      source: TrackSource.local,
      trackNumber: 3,
      duration: const Duration(minutes: 3, seconds: 30),
    );

    final tracks = await repository.watchAllTracks().first;

    expect(tracks, hasLength(1));
    expect(tracks.single.title, 'A Song');
    expect(tracks.single.trackNumber, 3);
    expect(tracks.single.duration, const Duration(minutes: 3, seconds: 30));
    expect(tracks.single.source, TrackSource.local);
  });

  test(
    'upsertTrack with an existing filePath updates instead of duplicating',
    () async {
      await repository.upsertTrack(
        filePath: '/music/song.mp3',
        title: 'Old title',
        artist: 'An Artist',
        album: 'An Album',
        source: TrackSource.local,
      );
      await repository.upsertTrack(
        filePath: '/music/song.mp3',
        title: 'New title',
        artist: 'An Artist',
        album: 'An Album',
        source: TrackSource.local,
      );

      final tracks = await repository.watchAllTracks().first;

      expect(tracks, hasLength(1));
      expect(tracks.single.title, 'New title');
    },
  );
}
