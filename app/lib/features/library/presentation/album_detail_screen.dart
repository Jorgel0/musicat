import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_providers.dart';
import '../domain/track.dart';
import 'library_providers.dart';

class AlbumDetailScreen extends ConsumerWidget {
  const AlbumDetailScreen({
    required this.albumName,
    required this.artistName,
    super.key,
  });

  final String albumName;
  final String artistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allTracks = ref.watch(tracksProvider).value ?? const [];
    final tracks =
        allTracks
            .where((t) => t.album == albumName && t.artist == artistName)
            .toList()
          ..sort((a, b) => (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0));

    String? coverArtPath;
    for (final track in tracks) {
      if (track.coverArtPath != null) {
        coverArtPath = track.coverArtPath;
        break;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(albumName),
        actions: [
          IconButton(
            tooltip: 'Play all',
            icon: const Icon(Icons.play_arrow),
            onPressed: () => _playAll(ref, tracks),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: coverArtPath != null
                        ? Image.file(File(coverArtPath), fit: BoxFit.cover)
                        : Container(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            alignment: Alignment.center,
                            child: const Icon(Icons.album),
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        albumName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        artistName,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        '${tracks.length} song(s)',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = tracks[index];
                return ListTile(
                  leading: SizedBox(
                    width: 28,
                    child: Text(
                      '${track.trackNumber ?? index + 1}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  title: Text(track.title),
                  onTap: () async {
                    final controller = ref.read(audioPlayerControllerProvider);
                    await controller.setQueue(tracks, initialIndex: index);
                    await controller.play();
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _playAll(WidgetRef ref, List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final controller = ref.read(audioPlayerControllerProvider);
    await controller.setQueue(tracks);
    await controller.play();
  }
}
