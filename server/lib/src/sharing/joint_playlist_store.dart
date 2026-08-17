import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'joint_playlist.dart';
import 'playlist_item.dart';

/// Persists this node's own copy of each [JointPlaylist] it participates
/// in, to `<dataDirectory>/joint_playlists.json`.
class JointPlaylistStore {
  JointPlaylistStore(this.dataDirectory);

  final Directory dataDirectory;

  File get _file => File(p.join(dataDirectory.path, 'joint_playlists.json'));

  Future<List<JointPlaylist>> loadAll() async {
    final file = _file;
    if (!file.existsSync()) return [];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return [
      for (final entry in json)
        JointPlaylist.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<JointPlaylist?> findById(String id) async {
    final playlists = await loadAll();
    for (final playlist in playlists) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  Future<void> save(JointPlaylist playlist) async {
    final playlists = await loadAll();
    playlists.removeWhere((p) => p.id == playlist.id);
    playlists.add(playlist);
    await _saveAll(playlists);
  }

  Future<void> remove(String id) async {
    final playlists = await loadAll();
    playlists.removeWhere((p) => p.id == id);
    await _saveAll(playlists);
  }

  /// Reconciles this node's local copy of a playlist with [remote] — another
  /// participant's view of the *same* playlist id, just fetched from their
  /// server. Returns the merged playlist (also persisted).
  ///
  /// Deliberately a per-item union by [PlaylistItem.id], not a whole-object
  /// last-write-wins replace: since adding a track is the only mutation
  /// participants actually do to each other's contributions (nobody edits
  /// someone else's item), a union can never lose a concurrent addition
  /// from either side the way replacing the whole object on a timestamp
  /// comparison would. [JointPlaylist.updatedAt] becomes whichever of the
  /// two is newer, so it still reflects "most recently touched by anyone".
  Future<JointPlaylist> mergeRemote(JointPlaylist remote) async {
    final local = await findById(remote.id);
    if (local == null) {
      await save(remote);
      return remote;
    }

    final byId = <String, PlaylistItem>{
      for (final item in local.items) item.id: item,
    };
    for (final item in remote.items) {
      byId.putIfAbsent(item.id, () => item);
    }
    final mergedItems = byId.values.toList()
      ..sort((a, b) => a.addedAt.compareTo(b.addedAt));

    final merged = local.copyWith(
      items: mergedItems,
      updatedAt: local.updatedAt.isAfter(remote.updatedAt)
          ? local.updatedAt
          : remote.updatedAt,
    );
    await save(merged);
    return merged;
  }

  Future<void> _saveAll(List<JointPlaylist> playlists) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final playlist in playlists) playlist.toJson()]),
    );
  }
}
