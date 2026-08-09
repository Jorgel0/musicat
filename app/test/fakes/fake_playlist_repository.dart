import 'package:musicat/features/library/domain/track.dart';
import 'package:musicat/features/playlists/domain/playlist.dart';
import 'package:musicat/features/playlists/domain/playlist_repository.dart';
import 'package:rxdart/rxdart.dart';

/// In-memory [PlaylistRepository] for widget tests that only exercise
/// playlist CRUD (e.g. [PlaylistsScreen]). Track management methods are
/// no-ops here — that behaviour is covered against the real Drift
/// repository in `playlist_repository_test.dart`.
class FakePlaylistRepository implements PlaylistRepository {
  final List<Playlist> _playlists = [];
  final _playlistsSubject = BehaviorSubject<List<Playlist>>.seeded(const []);
  int _nextId = 1;

  @override
  Stream<List<Playlist>> watchAllPlaylists() => _playlistsSubject.stream;

  @override
  Stream<Playlist?> watchPlaylist(int playlistId) {
    return _playlistsSubject.stream.map((playlists) {
      for (final playlist in playlists) {
        if (playlist.id == playlistId) return playlist;
      }
      return null;
    });
  }

  @override
  Stream<List<Track>> watchPlaylistTracks(int playlistId) =>
      Stream.value(const []);

  @override
  Future<int> createPlaylist(String name) async {
    final id = _nextId++;
    _playlists.add(Playlist(id: id, name: name, createdAt: DateTime(2026)));
    _playlistsSubject.add(List.of(_playlists));
    return id;
  }

  @override
  Future<void> renamePlaylist(int playlistId, String name) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return;
    _playlists[index] = Playlist(
      id: playlistId,
      name: name,
      createdAt: _playlists[index].createdAt,
    );
    _playlistsSubject.add(List.of(_playlists));
  }

  @override
  Future<void> deletePlaylist(int playlistId) async {
    _playlists.removeWhere((p) => p.id == playlistId);
    _playlistsSubject.add(List.of(_playlists));
  }

  @override
  Future<void> addTrack(int playlistId, int trackId) async {}

  @override
  Future<void> removeTrack(int playlistId, int trackId) async {}

  @override
  Future<void> reorderTrack(int playlistId, int oldIndex, int newIndex) async {}
}
