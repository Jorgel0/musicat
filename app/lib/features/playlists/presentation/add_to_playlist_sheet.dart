import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/domain/track.dart';
import 'playlist_providers.dart';
import 'prompt_playlist_name.dart';

Future<void> showAddToPlaylistSheet(BuildContext context, Track track) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AddToPlaylistSheet(track: track),
  );
}

class _AddToPlaylistSheet extends ConsumerWidget {
  const _AddToPlaylistSheet({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistsProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New playlist'),
            onTap: () => _createAndAdd(context, ref),
          ),
          const Divider(height: 1),
          Flexible(
            child: playlistsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, stackTrace) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: $error'),
              ),
              data: (playlists) {
                if (playlists.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No playlists yet.'),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(playlist.name),
                      onTap: () =>
                          _add(context, ref, playlist.id, playlist.name),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createAndAdd(BuildContext context, WidgetRef ref) async {
    final name = await promptPlaylistName(context);
    if (name == null || name.trim().isEmpty) return;
    final repository = ref.read(playlistRepositoryProvider);
    final id = await repository.createPlaylist(name.trim());
    await repository.addTrack(id, track.id);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _add(
    BuildContext context,
    WidgetRef ref,
    int playlistId,
    String playlistName,
  ) async {
    await ref.read(playlistRepositoryProvider).addTrack(playlistId, track.id);
    if (!context.mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Added to "$playlistName".')));
  }
}
