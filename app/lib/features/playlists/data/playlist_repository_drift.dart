import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../library/data/library_repository_drift.dart' show trackFromRow;
import '../../library/domain/track.dart';
import '../domain/playlist.dart';
import '../domain/playlist_repository.dart';

class DriftPlaylistRepository implements PlaylistRepository {
  DriftPlaylistRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<Playlist>> watchAllPlaylists() {
    final query = _db.select(_db.playlists)
      ..orderBy([
        (p) => OrderingTerm(expression: p.createdAt, mode: OrderingMode.desc),
      ]);
    return query.watch().map(
      (rows) => rows.map(_toDomain).toList(growable: false),
    );
  }

  @override
  Stream<Playlist?> watchPlaylist(int playlistId) {
    final query = _db.select(_db.playlists)
      ..where((p) => p.id.equals(playlistId));
    return query.watchSingleOrNull().map(
      (row) => row == null ? null : _toDomain(row),
    );
  }

  @override
  Stream<List<Track>> watchPlaylistTracks(int playlistId) {
    final query =
        _db.select(_db.playlistTracks).join([
            innerJoin(
              _db.tracks,
              _db.tracks.id.equalsExp(_db.playlistTracks.trackId),
            ),
          ])
          ..where(_db.playlistTracks.playlistId.equals(playlistId))
          ..orderBy([OrderingTerm(expression: _db.playlistTracks.position)]);

    return query.watch().map(
      (rows) => rows
          .map((row) => trackFromRow(row.readTable(_db.tracks)))
          .toList(growable: false),
    );
  }

  @override
  Future<int> createPlaylist(String name) {
    return _db
        .into(_db.playlists)
        .insert(PlaylistsCompanion.insert(name: name));
  }

  @override
  Future<void> renamePlaylist(int playlistId, String name) {
    return (_db.update(_db.playlists)..where((p) => p.id.equals(playlistId)))
        .write(PlaylistsCompanion(name: Value(name)));
  }

  @override
  Future<void> deletePlaylist(int playlistId) {
    return (_db.delete(
      _db.playlists,
    )..where((p) => p.id.equals(playlistId))).go();
  }

  @override
  Future<void> addTrack(int playlistId, int trackId) async {
    final existing = await (_db.select(
      _db.playlistTracks,
    )..where((pt) => pt.playlistId.equals(playlistId))).get();

    await _db
        .into(_db.playlistTracks)
        .insert(
          PlaylistTracksCompanion.insert(
            playlistId: playlistId,
            trackId: trackId,
            position: existing.length,
          ),
        );
  }

  @override
  Future<void> removeTrack(int playlistId, int trackId) {
    return (_db.delete(_db.playlistTracks)..where(
          (pt) => pt.playlistId.equals(playlistId) & pt.trackId.equals(trackId),
        ))
        .go();
  }

  @override
  Future<void> reorderTrack(int playlistId, int oldIndex, int newIndex) async {
    final rows =
        await (_db.select(_db.playlistTracks)
              ..where((pt) => pt.playlistId.equals(playlistId))
              ..orderBy([(pt) => OrderingTerm(expression: pt.position)]))
            .get();

    final reordered = List.of(rows);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);

    await _db.transaction(() async {
      for (var i = 0; i < reordered.length; i++) {
        await (_db.update(_db.playlistTracks)
              ..where((pt) => pt.id.equals(reordered[i].id)))
            .write(PlaylistTracksCompanion(position: Value(i)));
      }
    });
  }

  Playlist _toDomain(PlaylistRow row) {
    return Playlist(id: row.id, name: row.name, createdAt: row.createdAt);
  }
}
