import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'joint_playlist_providers.dart';

class JointPlaylistsTab extends ConsumerWidget {
  const JointPlaylistsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(jointPlaylistsProvider);

    return playlistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(child: Text('Error: $error')),
      data: (playlists) {
        if (playlists.isEmpty) {
          return const Center(
            child: Text(
              'No joint playlists yet — create one to share with friends.',
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(jointPlaylistsProvider.future),
          child: ListView.builder(
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              final participantCount = playlist.participantNodeIds.length + 1;
              return ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: Text(playlist.name),
                subtitle: Text(
                  '$participantCount participants · ${playlist.items.length} tracks',
                ),
                onTap: () => context.push('/joint-playlists/${playlist.id}'),
              );
            },
          ),
        );
      },
    );
  }
}
