import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/social/joint_playlist_client.dart';
import '../../friends/presentation/musicat_server_config_controller.dart';
import '../../library/domain/track.dart';

export '../../../core/network/social/joint_playlist_client.dart';

final jointPlaylistsProvider = FutureProvider<List<JointPlaylist>>((ref) {
  final client = ref.watch(jointPlaylistClientProvider);
  if (client == null) return Future.value(const []);
  return client.listPlaylists();
});

final jointPlaylistProvider = FutureProvider.family<JointPlaylist, String>((
  ref,
  id,
) {
  final client = ref.watch(jointPlaylistClientProvider);
  if (client == null) throw StateError('Musicat Server not configured');
  return client.getPlaylist(id);
});

/// Creates a new joint playlist, or joins one a friend already created by
/// passing its [id] — see server ADR 0026 on why the id has to be agreed
/// on out of band (there's no invite-link mechanism yet).
Future<String> createOrJoinJointPlaylist(
  WidgetRef ref, {
  required String name,
  required List<String> participantNodeIds,
  String? id,
}) async {
  final client = ref.read(jointPlaylistClientProvider);
  if (client == null) throw StateError('Musicat Server not configured');
  final newId = await client.createOrJoinPlaylist(
    name: name,
    participantNodeIds: participantNodeIds,
    id: id,
  );
  ref.invalidate(jointPlaylistsProvider);
  return newId;
}

Future<void> deleteJointPlaylist(WidgetRef ref, String id) async {
  final client = ref.read(jointPlaylistClientProvider);
  if (client == null) return;
  await client.deletePlaylist(id);
  ref.invalidate(jointPlaylistsProvider);
}

/// Adds [track] (from this node's own library) to the joint playlist
/// [playlistId] — the server shares it with exactly that playlist's other
/// participants (never wider, see ADR 0027).
Future<void> addTrackToJointPlaylist(
  WidgetRef ref, {
  required String playlistId,
  required Track track,
}) async {
  final client = ref.read(jointPlaylistClientProvider);
  if (client == null) throw StateError('Musicat Server not configured');
  await client.addItem(
    playlistId: playlistId,
    filePath: track.filePath,
    title: track.title,
    artist: track.artist,
    album: track.album,
    coverArtPath: track.coverArtPath,
  );
  ref.invalidate(jointPlaylistProvider(playlistId));
  ref.invalidate(jointPlaylistsProvider);
}

Future<JointPlaylistSyncResult> syncJointPlaylist(
  WidgetRef ref,
  String id,
) async {
  final client = ref.read(jointPlaylistClientProvider);
  if (client == null) throw StateError('Musicat Server not configured');
  final result = await client.sync(id);
  ref.invalidate(jointPlaylistProvider(id));
  ref.invalidate(jointPlaylistsProvider);
  return result;
}
