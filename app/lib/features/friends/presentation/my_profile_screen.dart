import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/social/sharing_client.dart';
import '../../library/presentation/library_providers.dart';
import 'my_profile_providers.dart';

/// Lets the user curate a "profile" — songs and albums visible to and
/// downloadable by *every* current friend, distinct from a one-off direct
/// share (see `share_with_friend_sheet.dart`).
class MyProfileScreen extends StatelessWidget {
  const MyProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My Profile'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Songs'),
              Tab(text: 'Albums'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_ProfileSongsTab(), _ProfileAlbumsTab()],
        ),
      ),
    );
  }
}

class _ProfileSongsTab extends ConsumerWidget {
  const _ProfileSongsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(tracksProvider);
    final profileAsync = ref.watch(myProfileTracksProvider);

    if (tracksAsync.isLoading || profileAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = tracksAsync.error ?? profileAsync.error;
    if (error != null) return Center(child: Text('Error: $error'));

    final tracks = tracksAsync.value ?? const [];
    if (tracks.isEmpty) {
      return const Center(child: Text('Your library is empty.'));
    }
    final profileByFilePath = {
      for (final share in profileAsync.value ?? const <MySharedTrack>[])
        share.filePath: share,
    };

    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final share = profileByFilePath[track.filePath];
        return CheckboxListTile(
          secondary: track.coverArtPath != null
              ? Image.file(
                  File(track.coverArtPath!),
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                )
              : const Icon(Icons.music_note, size: 48),
          title: Text(track.title),
          subtitle: Text('${track.artist} — ${track.album}'),
          value: share != null,
          onChanged: (checked) async {
            if (checked ?? false) {
              await addTrackToProfile(ref, track);
            } else if (share != null) {
              await removeTrackFromProfile(ref, share.id);
            }
          },
        );
      },
    );
  }
}

class _ProfileAlbumsTab extends ConsumerWidget {
  const _ProfileAlbumsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(tracksProvider);
    final albums = ref.watch(albumsProvider);
    final profileAsync = ref.watch(myProfileTracksProvider);

    if (tracksAsync.isLoading || profileAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = tracksAsync.error ?? profileAsync.error;
    if (error != null) return Center(child: Text('Error: $error'));

    if (albums.isEmpty) {
      return const Center(child: Text('Your library is empty.'));
    }
    final allTracks = tracksAsync.value ?? const [];
    final profileByFilePath = {
      for (final share in profileAsync.value ?? const <MySharedTrack>[])
        share.filePath: share,
    };

    return ListView.builder(
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        final albumTracks = allTracks
            .where(
              (t) =>
                  t.album.toLowerCase() == album.name.toLowerCase() &&
                  t.artist.toLowerCase() == album.artist.toLowerCase(),
            )
            .toList();
        final sharedCount = albumTracks
            .where((t) => profileByFilePath.containsKey(t.filePath))
            .length;
        final isFullyShared =
            albumTracks.isNotEmpty && sharedCount == albumTracks.length;

        return CheckboxListTile(
          secondary: album.coverArtPath != null
              ? Image.file(
                  File(album.coverArtPath!),
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                )
              : const Icon(Icons.album, size: 48),
          title: Text(album.name),
          subtitle: Text(album.artist),
          tristate: true,
          // Ignores the tristate cycle's own value -- checked/partial/none
          // is display-only. Tapping always means "make it fully shared"
          // unless it already is, in which case it means "remove it all".
          value: sharedCount == 0 ? false : (isFullyShared ? true : null),
          onChanged: (_) => isFullyShared
              ? removeAlbumFromProfile(
                  ref,
                  tracks: albumTracks,
                  profileByFilePath: profileByFilePath,
                )
              : addAlbumToProfile(
                  ref,
                  tracks: albumTracks,
                  alreadySharedFilePaths: profileByFilePath.keys.toSet(),
                ),
        );
      },
    );
  }
}
