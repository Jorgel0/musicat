import '../../library/domain/track.dart';
import 'playlist.dart';

abstract class PlaylistRepository {
  Stream<List<Playlist>> watchAllPlaylists();
  Stream<Playlist?> watchPlaylist(int playlistId);
  Stream<List<Track>> watchPlaylistTracks(int playlistId);

  Future<int> createPlaylist(String name);
  Future<void> renamePlaylist(int playlistId, String name);
  Future<void> deletePlaylist(int playlistId);

  Future<void> addTrack(int playlistId, int trackId);
  Future<void> removeTrack(int playlistId, int trackId);

  /// Moves the track at [oldIndex] to [newIndex] within the playlist's
  /// ordered track list (same index semantics as `ReorderableListView`).
  Future<void> reorderTrack(int playlistId, int oldIndex, int newIndex);
}
