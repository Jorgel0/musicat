import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_providers.dart';
import '../domain/track.dart';
import 'library_providers.dart';

class ArtistDetailScreen extends ConsumerWidget {
  const ArtistDetailScreen({required this.artistName, super.key});

  final String artistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allTracks = ref.watch(tracksProvider).value ?? const [];
    // Case-insensitive to match groupTracksByArtist's grouping (Soulseek
    // downloads often have inconsistent artist-name tag casing).
    final lowerArtistName = artistName.toLowerCase();
    final tracks =
        allTracks
            .where((t) => t.artist.toLowerCase() == lowerArtistName)
            .toList()
          ..sort((a, b) {
            final albumCompare = a.album.compareTo(b.album);
            if (albumCompare != 0) return albumCompare;
            return (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
          });

    return Scaffold(
      appBar: AppBar(
        title: Text(artistName),
        actions: [
          IconButton(
            tooltip: 'Play all',
            icon: const Icon(Icons.play_arrow),
            onPressed: () => _playAll(ref, tracks),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: tracks.length,
        itemBuilder: (context, index) {
          final track = tracks[index];
          return ListTile(
            title: Text(track.title),
            subtitle: Text(track.album),
            onTap: () async {
              final controller = ref.read(audioPlayerControllerProvider);
              await controller.setQueue(tracks, initialIndex: index);
              await controller.play();
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
}
