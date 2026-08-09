import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/audio/audio_providers.dart';
import '../../library/domain/track.dart';
import 'player_providers.dart';

/// Persistent bottom bar shown whenever a queue is loaded. Hidden entirely
/// until the first track is queued.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) return const SizedBox.shrink();

    final playing = ref.watch(playingProvider).value ?? false;
    final controller = ref.read(audioPlayerControllerProvider);

    return Material(
      elevation: 8,
      child: InkWell(
        onTap: () => context.push('/now-playing'),
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _MiniPlayerCover(track: track),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                onPressed: () =>
                    playing ? controller.pause() : controller.play(),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerCover extends StatelessWidget {
  const _MiniPlayerCover({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final path = track.coverArtPath;
    return SizedBox(
      width: 64,
      height: 64,
      child: path != null
          ? Image.file(File(path), fit: BoxFit.cover)
          : const Icon(Icons.music_note),
    );
  }
}
