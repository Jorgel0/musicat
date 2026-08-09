import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'playlist_providers.dart';
import 'prompt_playlist_name.dart';

class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New playlist'),
        onPressed: () => _createPlaylist(context, ref),
      ),
      body: playlistsAsync.when(
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
      ),
    );
  }

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final name = await promptPlaylistName(context);
    if (name == null || name.trim().isEmpty) return;
    await ref.read(playlistRepositoryProvider).createPlaylist(name.trim());
  }
}
