import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'playlist_providers.dart';

class LocalPlaylistsTab extends ConsumerWidget {
  const LocalPlaylistsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistsProvider);

    return playlistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(child: Text('Error: $error')),
      data: (playlists) {
        if (playlists.isEmpty) {
          return const Center(
            child: Text('No playlists yet — create one to get started.'),
          );
        }
        return ListView.builder(
          itemCount: playlists.length,
          itemBuilder: (context, index) {
            final playlist = playlists[index];
            return ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(playlist.name),
              onTap: () => context.push('/playlists/${playlist.id}'),
            );
          },
        );
      },
    );
  }
}
