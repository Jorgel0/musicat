import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// The local track catalog. `source` and `filePath` are plain text rather
/// than a Drift enum column so the domain layer (see
/// `features/library/domain/track.dart`) owns the actual enum and this
/// table stays a dumb persistence detail — see ADR 0003/0004.
@DataClassName('TrackRow')
class Tracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get filePath => text().unique()();
  TextColumn get title => text()();
  TextColumn get artist => text()();
  TextColumn get album => text()();
  IntColumn get trackNumber => integer().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get coverArtPath => text().nullable()();
  TextColumn get source => text()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('PlaylistRow')
class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('PlaylistTrackRow')
class PlaylistTracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get playlistId =>
      integer().references(Playlists, #id, onDelete: KeyAction.cascade)();
  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
  // Explicit ordering column rather than relying on row/insertion order, so
  // drag-to-reorder has somewhere deterministic to write to.
  IntColumn get position => integer()();
}

@DriftDatabase(tables: [Tracks, Playlists, PlaylistTracks])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'musicat'));

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(playlists);
        await m.createTable(playlistTracks);
      }
    },
    // SQLite ignores foreign key constraints (so the playlist_tracks
    // CASCADE deletes above are a no-op) unless enforcement is turned on
    // per connection.
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
