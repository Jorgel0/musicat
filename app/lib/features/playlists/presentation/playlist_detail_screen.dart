import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_providers.dart';
import '../../library/domain/track.dart';
import 'playlist_providers.dart';
import 'prompt_playlist_name.dart';

class PlaylistDetailScreen extends ConsumerWidget {
  const PlaylistDetailScreen({required this.playlistId, super.key});

  final int playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlist = ref.watch(playlistProvider(playlistId)).value;
    final tracksAsync = ref.watch(playlistTracksProvider(playlistId));
    final repository = ref.read(playlistRepositoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(playlist?.name ?? 'Playlist'),
        actions: [
          IconButton(
            tooltip: 'Play all',
            icon: const Icon(Icons.play_arrow),
            onPressed: () => _playAll(ref, tracksAsync.value ?? const []),
          ),
          PopupMenuButton<_PlaylistAction>(
            onSelected: (action) =>
                _handleAction(context, ref, action, playlist?.name),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _PlaylistAction.rename,
                child: Text('Rename'),
              ),
              PopupMenuItem(
                value: _PlaylistAction.delete,
                child: Text('Delete'),
              ),
            ],
          ),
        ],
      ),
      body: tracksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text('Error: $error')),
        data: (tracks) {
          if (tracks.isEmpty) {
            return const Center(
              child: Text('No tracks yet — add some from the library.'),
            );
          }
          return ReorderableListView.builder(
            itemCount: tracks.length,
            onReorderItem: (oldIndex, newIndex) {
              repository.reorderTrack(playlistId, oldIndex, newIndex);
            },
            itemBuilder: (context, index) {
              final track = tracks[index];
              return ListTile(
                key: ValueKey(track.id),
                leading: track.coverArtPath != null
                    ? Image.file(
                        File(track.coverArtPath!),
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      )
                    : const Icon(Icons.music_note),
                title: Text(track.title),
                subtitle: Text(track.artist),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => repository.removeTrack(playlistId, track.id),
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
      ),
    );
  }

  Future<void> _playAll(WidgetRef ref, List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final controller = ref.read(audioPlayerControllerProvider);
    await controller.setQueue(tracks);
    await controller.play();
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    _PlaylistAction action,
    String? currentName,
  ) async {
    final repository = ref.read(playlistRepositoryProvider);
    switch (action) {
      case _PlaylistAction.rename:
        final name = await promptPlaylistName(
          context,
          initialValue: currentName,
        );
        if (name != null && name.trim().isNotEmpty) {
          await repository.renamePlaylist(playlistId, name.trim());
        }
      case _PlaylistAction.delete:
        await repository.deletePlaylist(playlistId);
        if (context.mounted) Navigator.of(context).pop();
    }
  }
}

enum _PlaylistAction { rename, delete }
