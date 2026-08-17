import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'shared_track.dart';

/// Persists this node's outgoing shares to
/// `<dataDirectory>/shared_tracks.json`.
class SharedTrackStore {
  SharedTrackStore(this.dataDirectory);

  final Directory dataDirectory;

  File get _file => File(p.join(dataDirectory.path, 'shared_tracks.json'));

  Future<List<SharedTrack>> loadAll() async {
    final file = _file;
    if (!file.existsSync()) return [];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return [
      for (final entry in json)
        SharedTrack.fromStorageJson(entry as Map<String, dynamic>),
    ];
  }

  Future<SharedTrack?> findById(String id) async {
    final tracks = await loadAll();
    for (final track in tracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  /// Tracks visible to [requestingNodeId] — the object-level authz filter
  /// (see [SharedTrackVisibility.allows]): only tracks this specific node
  /// is actually allowed to see, never "every track shared with anyone".
  Future<List<SharedTrack>> visibleTo(String requestingNodeId) async {
    final tracks = await loadAll();
    return tracks
        .where((track) => track.visibility.allows(requestingNodeId))
        .toList();
  }

  Future<void> add(SharedTrack track) async {
    final tracks = await loadAll();
    tracks.removeWhere((t) => t.id == track.id);
    tracks.add(track);
    await _save(tracks);
  }

  Future<void> remove(String id) async {
    final tracks = await loadAll();
    tracks.removeWhere((t) => t.id == id);
    await _save(tracks);
  }

  Future<void> _save(List<SharedTrack> tracks) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final track in tracks) track.toStorageJson()]),
    );
  }
}
