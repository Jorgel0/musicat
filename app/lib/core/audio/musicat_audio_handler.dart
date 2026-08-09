import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../../features/library/domain/track.dart';
import 'audio_player_controller.dart';
import 'equalizer_info.dart';
import 'playback_processing_state.dart';
import 'repeat_mode.dart';

/// [AudioPlayerController] backed by `just_audio` (decoding/playback) and
/// `audio_service` (Android notification, lockscreen, and media-button
/// integration). `currentIndex`/`queue` are always in the original,
/// unshuffled order that [setQueue] was called with — just_audio reports
/// [AudioPlayer.currentIndex] in that same order regardless of shuffle mode,
/// so no separate shuffle-aware remapping is needed for our own UI.
class MusicatAudioHandler extends BaseAudioHandler
    with SeekHandler
    implements AudioPlayerController {
  MusicatAudioHandler() {
    _init();
  }

  // just_audio's own built-in Android equalizer support (backed by
  // android.media.audiofx.Equalizer) — there's no equivalent on
  // Linux/Windows (media_kit) or iOS/macOS, so it's Android-only by
  // construction. See ADR 0007.
  final AndroidEqualizer? _equalizer = Platform.isAndroid
      ? AndroidEqualizer()
      : null;
  late final AudioPlayer _player = AudioPlayer(
    audioPipeline: AudioPipeline(
      androidAudioEffects: [if (_equalizer != null) _equalizer],
    ),
  );
  List<Track> _tracks = const [];
  final _queueSubject = BehaviorSubject<List<Track>>.seeded(const []);
  final _currentTrackSubject = BehaviorSubject<Track?>.seeded(null);

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _player.playbackEventStream.listen(_broadcastPlaybackState);
    _player.shuffleModeEnabledStream.listen(
      (_) => _broadcastPlaybackState(_player.playbackEvent),
    );
    _player.loopModeStream.listen(
      (_) => _broadcastPlaybackState(_player.playbackEvent),
    );
    _player.currentIndexStream.listen((index) {
      final track = (index != null && index >= 0 && index < _tracks.length)
          ? _tracks[index]
          : null;
      _currentTrackSubject.add(track);
      if (track != null) mediaItem.add(_trackToMediaItem(track));
    });

    // Safety net for a rare, not-yet-reproduced report: the player once sat
    // on ProcessingState.completed with repeat-all on and never advanced
    // back to the first track. If that happens again, nudge it forward
    // manually instead of silently stalling. This is a no-op in the normal
    // case, since just_audio/media_kit will have already advanced within
    // the delay below.
    _player.processingStateStream
        .where((state) => state == ProcessingState.completed)
        .listen((_) async {
          final loopMode = _player.loopMode;
          if (loopMode == LoopMode.off) return;
          final stalledIndex = _player.currentIndex;
          await Future<void>.delayed(const Duration(milliseconds: 800));
          final stillStalled =
              _player.processingState == ProcessingState.completed &&
              _player.currentIndex == stalledIndex;
          if (!stillStalled) return;
          if (loopMode == LoopMode.all) {
            await _player.seek(Duration.zero, index: 0);
          } else {
            await _player.seek(Duration.zero, index: stalledIndex);
          }
          await _player.play();
        });
  }

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<int?> get currentIndexStream => _player.currentIndexStream;

  @override
  Stream<List<Track>> get queueStream => _queueSubject.stream;

  @override
  Stream<Track?> get currentTrackStream => _currentTrackSubject.stream;

  @override
  Stream<bool> get shuffleModeEnabledStream => _player.shuffleModeEnabledStream;

  @override
  Stream<PlaybackRepeatMode> get repeatModeStream =>
      _player.loopModeStream.map(_repeatModeFromLoopMode);

  @override
  Stream<PlaybackProcessingState> get processingStateStream =>
      _player.processingStateStream.map(_processingStateFrom);

  @override
  Future<void> setQueue(List<Track> tracks, {int initialIndex = 0}) async {
    _tracks = tracks;
    _queueSubject.add(tracks);
    queue.add(tracks.map(_trackToMediaItem).toList());

    if (tracks.isEmpty) {
      await _player.stop();
      _currentTrackSubject.add(null);
      mediaItem.add(null);
      return;
    }

    final sources = tracks.map((t) => AudioSource.file(t.filePath)).toList();
    await _player.setAudioSources(sources, initialIndex: initialIndex);
    _currentTrackSubject.add(tracks[initialIndex]);
    mediaItem.add(_trackToMediaItem(tracks[initialIndex]));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToQueueItem(int index) =>
      _player.seek(Duration.zero, index: index);

  @override
  Future<void> setShuffleModeEnabled(bool enabled) async {
    if (enabled) {
      await _player.shuffle();
    }
    await _player.setShuffleModeEnabled(enabled);
  }

  @override
  Future<void> setRepeat(PlaybackRepeatMode mode) =>
      _player.setLoopMode(_loopModeFromRepeatMode(mode));

  @override
  Future<EqualizerInfo?> getEqualizerInfo() async {
    final equalizer = _equalizer;
    if (equalizer == null) return null;
    // Only resolves once the player has loaded at least one audio source
    // (that's when just_audio activates the pipeline's effects) — callers
    // are expected to only ask once something has been queued.
    final params = await equalizer.parameters;
    return EqualizerInfo(
      enabled: equalizer.enabled,
      minDecibels: params.minDecibels,
      maxDecibels: params.maxDecibels,
      bands: [
        for (final band in params.bands)
          EqualizerBandInfo(
            index: band.index,
            centerFrequencyHz: band.centerFrequency,
            gainDb: band.gain,
          ),
      ],
    );
  }

  @override
  Future<void> setEqualizerEnabled(bool enabled) async {
    await _equalizer?.setEnabled(enabled);
  }

  @override
  Future<void> setEqualizerBandGain(int bandIndex, double gainDb) async {
    final equalizer = _equalizer;
    if (equalizer == null) return;
    final params = await equalizer.parameters;
    await params.bands[bandIndex].setGain(gainDb);
  }

  // -- AudioHandler overrides: let system-triggered changes (Android Auto,
  // Bluetooth remotes) flow back through the same just_audio calls. Named
  // differently from our own interface's setShuffleModeEnabled/setRepeat
  // above since AudioHandler's setShuffleMode/setRepeatMode take
  // audio_service's own enums, not ours.
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      setShuffleModeEnabled(shuffleMode == AudioServiceShuffleMode.all);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      setRepeat(_repeatModeFromAudioService(repeatMode));

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  Future<void> disposePlayer() => _player.dispose();

  MediaItem _trackToMediaItem(Track track) => MediaItem(
    id: track.filePath,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.duration,
    artUri: track.coverArtPath != null ? Uri.file(track.coverArtPath!) : null,
  );

  void _broadcastPlaybackState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 3],
        processingState: _audioServiceProcessingStateFrom(
          _player.processingState,
        ),
        repeatMode: _audioServiceRepeatModeFrom(
          _repeatModeFromLoopMode(_player.loopMode),
        ),
        shuffleMode: _player.shuffleModeEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
      ),
    );
  }
}

PlaybackRepeatMode _repeatModeFromLoopMode(LoopMode mode) => switch (mode) {
  LoopMode.off => PlaybackRepeatMode.off,
  LoopMode.one => PlaybackRepeatMode.one,
  LoopMode.all => PlaybackRepeatMode.all,
};

LoopMode _loopModeFromRepeatMode(PlaybackRepeatMode mode) => switch (mode) {
  PlaybackRepeatMode.off => LoopMode.off,
  PlaybackRepeatMode.one => LoopMode.one,
  PlaybackRepeatMode.all => LoopMode.all,
};

PlaybackRepeatMode _repeatModeFromAudioService(AudioServiceRepeatMode mode) =>
    switch (mode) {
      AudioServiceRepeatMode.none => PlaybackRepeatMode.off,
      AudioServiceRepeatMode.one => PlaybackRepeatMode.one,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => PlaybackRepeatMode.all,
    };

AudioServiceRepeatMode _audioServiceRepeatModeFrom(PlaybackRepeatMode mode) =>
    switch (mode) {
      PlaybackRepeatMode.off => AudioServiceRepeatMode.none,
      PlaybackRepeatMode.one => AudioServiceRepeatMode.one,
      PlaybackRepeatMode.all => AudioServiceRepeatMode.all,
    };

PlaybackProcessingState _processingStateFrom(ProcessingState state) =>
    switch (state) {
      ProcessingState.idle => PlaybackProcessingState.idle,
      ProcessingState.loading => PlaybackProcessingState.loading,
      ProcessingState.buffering => PlaybackProcessingState.buffering,
      ProcessingState.ready => PlaybackProcessingState.ready,
      ProcessingState.completed => PlaybackProcessingState.completed,
    };

AudioProcessingState _audioServiceProcessingStateFrom(ProcessingState state) =>
    switch (state) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
