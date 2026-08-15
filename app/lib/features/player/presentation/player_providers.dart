import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_providers.dart';
import '../../../core/audio/playback_processing_state.dart';
import '../../../core/audio/repeat_mode.dart';
import '../../library/domain/track.dart';

final playingProvider = StreamProvider<bool>((ref) {
  return ref.watch(audioPlayerControllerProvider).playingStream;
});

final positionProvider = StreamProvider<Duration>((ref) {
  return ref.watch(audioPlayerControllerProvider).positionStream;
});

final durationProvider = StreamProvider<Duration?>((ref) {
  return ref.watch(audioPlayerControllerProvider).durationStream;
});

final currentIndexProvider = StreamProvider<int?>((ref) {
  return ref.watch(audioPlayerControllerProvider).currentIndexStream;
});

final playbackQueueProvider = StreamProvider<List<Track>>((ref) {
  return ref.watch(audioPlayerControllerProvider).queueStream;
});

final shuffleModeEnabledProvider = StreamProvider<bool>((ref) {
  return ref.watch(audioPlayerControllerProvider).shuffleModeEnabledStream;
});

final repeatModeProvider = StreamProvider<PlaybackRepeatMode>((ref) {
  return ref.watch(audioPlayerControllerProvider).repeatModeStream;
});

final processingStateProvider = StreamProvider<PlaybackProcessingState>((ref) {
  return ref.watch(audioPlayerControllerProvider).processingStateStream;
});

final volumeProvider = StreamProvider<double>((ref) {
  return ref.watch(audioPlayerControllerProvider).volumeStream;
});

final _currentTrackStreamProvider = StreamProvider<Track?>((ref) {
  return ref.watch(audioPlayerControllerProvider).currentTrackStream;
});

/// The track at [currentIndexProvider] within [playbackQueueProvider], or
/// `null` if nothing is queued yet. Exposed as a plain `Track?` (rather than
/// an `AsyncValue`) for convenience at call sites.
final currentTrackProvider = Provider<Track?>((ref) {
  return ref.watch(_currentTrackStreamProvider).value;
});
