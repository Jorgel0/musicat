import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_providers.dart';
import '../../../core/audio/repeat_mode.dart';
import '../../library/domain/track.dart';
import 'player_providers.dart';

class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final playing = ref.watch(playingProvider).value ?? false;
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? Duration.zero;
    final shuffleEnabled = ref.watch(shuffleModeEnabledProvider).value ?? false;
    final repeatMode =
        ref.watch(repeatModeProvider).value ?? PlaybackRepeatMode.off;
    final controller = ref.read(audioPlayerControllerProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Now Playing'),
      ),
      body: track == null
          ? const Center(child: Text('Nothing playing yet.'))
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Expanded(child: _Cover(track: track)),
                    const SizedBox(height: 24),
                    Text(
                      track.title,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${track.artist} — ${track.album}',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    _SeekBar(
                      position: position,
                      duration: duration,
                      onSeek: controller.seek,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.shuffle,
                            color: shuffleEnabled
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          onPressed: () =>
                              controller.setShuffleModeEnabled(!shuffleEnabled),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_previous),
                          iconSize: 36,
                          onPressed: controller.skipToPrevious,
                        ),
                        IconButton(
                          icon: Icon(
                            playing
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                          ),
                          iconSize: 64,
                          onPressed: () =>
                              playing ? controller.pause() : controller.play(),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next),
                          iconSize: 36,
                          onPressed: controller.skipToNext,
                        ),
                        IconButton(
                          icon: Icon(
                            repeatMode == PlaybackRepeatMode.one
                                ? Icons.repeat_one
                                : Icons.repeat,
                            color: repeatMode != PlaybackRepeatMode.off
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          onPressed: () =>
                              controller.setRepeat(_nextRepeatMode(repeatMode)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
    );
  }
}

PlaybackRepeatMode _nextRepeatMode(PlaybackRepeatMode mode) => switch (mode) {
  PlaybackRepeatMode.off => PlaybackRepeatMode.all,
  PlaybackRepeatMode.all => PlaybackRepeatMode.one,
  PlaybackRepeatMode.one => PlaybackRepeatMode.off,
};

class _Cover extends StatelessWidget {
  const _Cover({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final path = track.coverArtPath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 1,
        child: path != null
            ? Image.file(File(path), fit: BoxFit.cover)
            : Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.music_note, size: 96),
              ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragValueMs;

  @override
  Widget build(BuildContext context) {
    final maxMs = widget.duration.inMilliseconds > 0
        ? widget.duration.inMilliseconds.toDouble()
        : 1.0;
    final positionMs = widget.position.inMilliseconds.toDouble().clamp(
      0.0,
      maxMs,
    );

    return Column(
      children: [
        Slider(
          min: 0,
          max: maxMs,
          value: _dragValueMs ?? positionMs,
          onChanged: widget.duration == Duration.zero
              ? null
              : (value) => setState(() => _dragValueMs = value),
          onChangeEnd: (value) {
            widget.onSeek(Duration(milliseconds: value.round()));
            setState(() => _dragValueMs = null);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(widget.position)),
              Text(_formatDuration(widget.duration)),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
}
