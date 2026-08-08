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

@DriftDatabase(tables: [Tracks])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'musicat'));

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;
}
