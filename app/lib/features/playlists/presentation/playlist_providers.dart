import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../library/domain/track.dart';
import '../data/playlist_repository_drift.dart';
import '../domain/playlist.dart';
import '../domain/playlist_repository.dart';

final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  return DriftPlaylistRepository(ref.watch(appDatabaseProvider));
});

final playlistsProvider = StreamProvider<List<Playlist>>((ref) {
  return ref.watch(playlistRepositoryProvider).watchAllPlaylists();
});

final playlistProvider = StreamProvider.family<Playlist?, int>((ref, id) {
  return ref.watch(playlistRepositoryProvider).watchPlaylist(id);
});

final playlistTracksProvider = StreamProvider.family<List<Track>, int>((
  ref,
  id,
) {
  return ref.watch(playlistRepositoryProvider).watchPlaylistTracks(id);
});
