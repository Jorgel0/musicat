import 'package:audio_service/audio_service.dart';

import 'musicat_audio_handler.dart';

/// Must be awaited before `runApp` so the returned handler can be provided
/// via Riverpod before any widget tries to read it.
Future<MusicatAudioHandler> initAudioService() {
  return AudioService.init(
    builder: () => MusicatAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.musicat.musicat.channel.audio',
      androidNotificationChannelName: 'Musicat playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
}
