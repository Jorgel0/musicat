import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/social/sharing_client.dart';
import '../../library/domain/track.dart';
import 'musicat_server_config_controller.dart';

/// This node's own "profile" shares — the subset of [SharingClient.listMyShares]
/// visible to *every* current friend, as opposed to a direct send to one or
/// more specific friends (the plan's "perfil personalizable" idea).
final myProfileTracksProvider = FutureProvider<List<MySharedTrack>>((
  ref,
) async {
  final client = ref.watch(sharingClientProvider);
  if (client == null) return const [];
  final shares = await client.listMyShares();
  return [
    for (final share in shares)
      if (share.isAllFriends) share,
  ];
});

Future<void> addTrackToProfile(WidgetRef ref, Track track) async {
  final client = ref.read(sharingClientProvider);
  if (client == null) throw StateError('Musicat Server not configured');
  await client.shareTrack(
    filePath: track.filePath,
    title: track.title,
    artist: track.artist,
    album: track.album,
    coverArtPath: track.coverArtPath,
    visibility: const {'type': 'allFriends'},
  );
  ref.invalidate(myProfileTracksProvider);
}

Future<void> removeTrackFromProfile(WidgetRef ref, String sharedTrackId) async {
  final client = ref.read(sharingClientProvider);
  if (client == null) return;
  await client.deleteShare(sharedTrackId);
  ref.invalidate(myProfileTracksProvider);
}

/// Adds every one of [tracks] (an album's worth) to the profile that
/// isn't already in it.
Future<void> addAlbumToProfile(
  WidgetRef ref, {
  required List<Track> tracks,
  required Set<String> alreadySharedFilePaths,
}) async {
  final client = ref.read(sharingClientProvider);
  if (client == null) throw StateError('Musicat Server not configured');
  for (final track in tracks) {
    if (alreadySharedFilePaths.contains(track.filePath)) continue;
    await client.shareTrack(
      filePath: track.filePath,
      title: track.title,
      artist: track.artist,
      album: track.album,
      coverArtPath: track.coverArtPath,
      visibility: const {'type': 'allFriends'},
    );
  }
  ref.invalidate(myProfileTracksProvider);
}

/// Removes every profile share ([profileByFilePath]) matching [tracks].
Future<void> removeAlbumFromProfile(
  WidgetRef ref, {
  required List<Track> tracks,
  required Map<String, MySharedTrack> profileByFilePath,
}) async {
  final client = ref.read(sharingClientProvider);
  if (client == null) return;
  for (final track in tracks) {
    final share = profileByFilePath[track.filePath];
    if (share == null) continue;
    await client.deleteShare(share.id);
  }
  ref.invalidate(myProfileTracksProvider);
}
