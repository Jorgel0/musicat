import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/library_repository.dart';
import '../domain/track.dart';

/// Shared with `features/playlists/data` so both repositories map a
/// [TrackRow] to the domain [Track] the same way.
Track trackFromRow(TrackRow row) {
  return Track(
    id: row.id,
    filePath: row.filePath,
    title: row.title,
    artist: row.artist,
    album: row.album,
    source: TrackSource.values.byName(row.source),
    trackNumber: row.trackNumber,
    duration: row.durationMs == null
        ? null
        : Duration(milliseconds: row.durationMs!),
    coverArtPath: row.coverArtPath,
  );
}

class DriftLibraryRepository implements LibraryRepository {
  DriftLibraryRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Track>> watchAllTracks() {
    return _db
        .select(_db.tracks)
        .watch()
        .map((rows) => rows.map(trackFromRow).toList(growable: false));
  }

  @override
  Future<void> upsertTrack({
    required String filePath,
    required String title,
    required String artist,
    required String album,
    required TrackSource source,
    int? trackNumber,
    Duration? duration,
    String? coverArtPath,
  }) {
    final companion = TracksCompanion.insert(
      filePath: filePath,
      title: title,
      artist: artist,
      album: album,
      source: source.name,
      trackNumber: Value(trackNumber),
      durationMs: Value(duration?.inMilliseconds),
      coverArtPath: Value(coverArtPath),
    );
    // `filePath` (not the auto-increment `id`) is the real identity of a
    // track, so the upsert has to target it explicitly — Drift's default
    // conflict target is the primary key.
    return _db
        .into(_db.tracks)
        .insert(
          companion,
          onConflict: DoUpdate((_) => companion, target: [_db.tracks.filePath]),
        );
  }

  @override
  Stream<List<String>> watchFolders() {
    final query = _db.select(_db.watchedFolders)
      ..orderBy([(f) => OrderingTerm(expression: f.addedAt)]);
    return query.watch().map(
      (rows) => rows.map((row) => row.path).toList(growable: false),
    );
  }

  @override
  Future<void> addFolder(String path) {
    return _db
        .into(_db.watchedFolders)
        .insert(
          WatchedFoldersCompanion.insert(path: path),
          mode: InsertMode.insertOrIgnore,
        );
  }

  @override
  Future<void> removeFolder(String path) {
    return (_db.delete(
      _db.watchedFolders,
    )..where((f) => f.path.equals(path))).go();
  }
}
