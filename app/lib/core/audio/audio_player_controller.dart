import '../../features/library/domain/track.dart';
import 'equalizer_info.dart';
import 'playback_processing_state.dart';
import 'repeat_mode.dart';

/// The interface the rest of the app talks to for playback. Kept free of any
/// specific audio engine so the UI, providers, and tests never depend on
/// `just_audio`/`audio_service` directly — only [MusicatAudioHandler] does.
abstract class AudioPlayerController {
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<int?> get currentIndexStream;
  Stream<List<Track>> get queueStream;

  /// The track at [currentIndexStream] within [queueStream], or `null` if
  /// nothing is queued. Combined here (rather than left for callers to derive
  /// from the two streams above) since consumers only ever need the pair
  /// together.
  Stream<Track?> get currentTrackStream;
  Stream<bool> get shuffleModeEnabledStream;
  Stream<PlaybackRepeatMode> get repeatModeStream;
  Stream<PlaybackProcessingState> get processingStateStream;

  /// Replaces the queue and starts loading [initialIndex].
  Future<void> setQueue(List<Track> tracks, {int initialIndex = 0});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> skipToNext();
  Future<void> skipToPrevious();
  Future<void> skipToQueueItem(int index);
  Future<void> setShuffleModeEnabled(bool enabled);
  Future<void> setRepeat(PlaybackRepeatMode mode);

  /// `null` if no track has been loaded yet, or the equalizer isn't
  /// supported on this platform (Android only for now — see ADR 0007).
  Future<EqualizerInfo?> getEqualizerInfo();
  Future<void> setEqualizerEnabled(bool enabled);
  Future<void> setEqualizerBandGain(int bandIndex, double gainDb);
}
