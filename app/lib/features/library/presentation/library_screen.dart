import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_providers.dart';
import '../../playlists/presentation/add_to_playlist_sheet.dart';
import 'albums_tab.dart';
import 'artists_tab.dart';
import 'library_providers.dart';
import 'pick_and_scan_folder.dart';
import 'share_with_friend_sheet.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Musicat'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Songs'),
              Tab(text: 'Albums'),
              Tab(text: 'Artists'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Add folder'),
          onPressed: () => pickAndScanFolder(context, ref),
        ),
        body: const TabBarView(
          children: [_SongsTab(), AlbumsTab(), ArtistsTab()],
        ),
      ),
    );
  }
}

class _SongsTab extends ConsumerWidget {
  const _SongsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(tracksProvider);

    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(child: Text('Error: $error')),
      data: (tracks) {
        if (tracks.isEmpty) {
          return const Center(
            child: Text('No tracks yet — add a music folder to get started.'),
          );
        }
        return ListView.builder(
          itemCount: tracks.length,
          itemBuilder: (context, index) {
            final track = tracks[index];
            return ListTile(
              leading: track.coverArtPath != null
                  ? Image.file(
                      File(track.coverArtPath!),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                    )
                  : const Icon(Icons.music_note, size: 48),
              title: Text(track.title),
              subtitle: Text('${track.artist} — ${track.album}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.person_add_alt_outlined),
                    tooltip: 'Share with a friend',
                    onPressed: () => showShareWithFriendSheet(context, track),
                  ),
                  IconButton(
                    icon: const Icon(Icons.playlist_add),
                    tooltip: 'Add to playlist',
                    onPressed: () => showAddToPlaylistSheet(context, track),
                  ),
                ],
              ),
              onTap: () async {
                final controller = ref.read(audioPlayerControllerProvider);
                await controller.setQueue(tracks, initialIndex: index);
                await controller.play();
              },
            );
          },
        );
      },
    );
  }
}
