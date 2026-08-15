import 'package:musicat/core/audio/audio_player_controller.dart';
import 'package:musicat/core/audio/equalizer_info.dart';
import 'package:musicat/core/audio/playback_processing_state.dart';
import 'package:musicat/core/audio/repeat_mode.dart';
import 'package:musicat/features/library/domain/track.dart';
import 'package:rxdart/rxdart.dart';

/// In-memory [AudioPlayerController] for tests. Uses [BehaviorSubject]s (like
/// the real just_audio/audio_service streams) so a provider that starts
/// listening after a call to e.g. [setQueue] still sees the latest state,
/// rather than only future changes.
class FakeAudioPlayerController implements AudioPlayerController {
  final _playing = BehaviorSubject.seeded(false);
  final _position = BehaviorSubject.seeded(Duration.zero);
  final _duration = BehaviorSubject<Duration?>.seeded(null);
  final _currentIndex = BehaviorSubject<int?>.seeded(null);
  final _queue = BehaviorSubject<List<Track>>.seeded(const []);
  final _currentTrack = BehaviorSubject<Track?>.seeded(null);
  final _shuffleModeEnabled = BehaviorSubject.seeded(false);
  final _repeatMode = BehaviorSubject.seeded(PlaybackRepeatMode.off);
  final _processingState = BehaviorSubject.seeded(PlaybackProcessingState.idle);

  /// Names of controller methods invoked, in call order — for asserting the
  /// UI wired the right action to the right button.
  final List<String> calls = [];

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  Stream<int?> get currentIndexStream => _currentIndex.stream;
  @override
  Stream<List<Track>> get queueStream => _queue.stream;
  @override
  Stream<Track?> get currentTrackStream => _currentTrack.stream;
  @override
  Stream<bool> get shuffleModeEnabledStream => _shuffleModeEnabled.stream;
  @override
  Stream<PlaybackRepeatMode> get repeatModeStream => _repeatMode.stream;
  @override
  Stream<PlaybackProcessingState> get processingStateStream =>
      _processingState.stream;

  @override
  Future<void> setQueue(List<Track> tracks, {int initialIndex = 0}) async {
    calls.add('setQueue');
    _queue.add(tracks);
    _currentIndex.add(tracks.isEmpty ? null : initialIndex);
    _currentTrack.add(tracks.isEmpty ? null : tracks[initialIndex]);
    _duration.add(null);
    _position.add(Duration.zero);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    _position.add(position);
  }

  @override
  Future<void> skipToNext() async {
    calls.add('skipToNext');
    final queue = _queue.value;
    final index = _currentIndex.value;
    if (index != null && index + 1 < queue.length) {
      _setCurrentIndex(index + 1);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    calls.add('skipToPrevious');
    final index = _currentIndex.value;
    if (index != null && index > 0) {
      _setCurrentIndex(index - 1);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    calls.add('skipToQueueItem');
    _setCurrentIndex(index);
  }

  void _setCurrentIndex(int index) {
    _currentIndex.add(index);
    final queue = _queue.value;
    _currentTrack.add(index >= 0 && index < queue.length ? queue[index] : null);
  }

  @override
  Future<void> setShuffleModeEnabled(bool enabled) async {
    calls.add('setShuffleModeEnabled');
    _shuffleModeEnabled.add(enabled);
  }

  @override
  Future<void> setRepeat(PlaybackRepeatMode mode) async {
    calls.add('setRepeat');
    _repeatMode.add(mode);
  }

  bool equalizerSupported = true;
  bool equalizerEnabled = false;
  final List<double> equalizerBandGains = [0, 0, 0, 0, 0];
  static const _bandCenterFrequencies = [60.0, 230.0, 910.0, 3600.0, 14000.0];

  @override
  Future<EqualizerInfo?> getEqualizerInfo() async {
    calls.add('getEqualizerInfo');
    if (!equalizerSupported) return null;
    return EqualizerInfo(
      enabled: equalizerEnabled,
      minDecibels: -15,
      maxDecibels: 15,
      bands: [
        for (var i = 0; i < _bandCenterFrequencies.length; i++)
          EqualizerBandInfo(
            index: i,
            centerFrequencyHz: _bandCenterFrequencies[i],
            gainDb: equalizerBandGains[i],
          ),
      ],
    );
  }

  @override
  Future<void> setEqualizerEnabled(bool enabled) async {
    calls.add('setEqualizerEnabled');
    equalizerEnabled = enabled;
  }

  @override
  Future<void> setEqualizerBandGain(int bandIndex, double gainDb) async {
    calls.add('setEqualizerBandGain');
    equalizerBandGains[bandIndex] = gainDb;
  }

  final _normalizationEnabled = BehaviorSubject.seeded(true);

  @override
  Stream<bool> get normalizationEnabledStream => _normalizationEnabled.stream;

  @override
  Future<void> setNormalizationEnabled(bool enabled) async {
    calls.add('setNormalizationEnabled');
    _normalizationEnabled.add(enabled);
  }

  final _volume = BehaviorSubject<double>.seeded(1.0);

  @override
  Stream<double> get volumeStream => _volume.stream;

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume');
    _volume.add(volume.clamp(0.0, 1.0));
  }

  Future<void> dispose() async {
    await Future.wait([
      _playing.close(),
      _position.close(),
      _duration.close(),
      _currentIndex.close(),
      _queue.close(),
      _currentTrack.close(),
      _shuffleModeEnabled.close(),
      _repeatMode.close(),
      _processingState.close(),
      _normalizationEnabled.close(),
      _volume.close(),
    ]);
  }
}
