import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio_player_controller.dart';

/// Overridden at bootstrap with the real [MusicatAudioHandler] (once
/// `AudioService.init` has resolved) or, in tests, with a fake.
final audioPlayerControllerProvider = Provider<AudioPlayerController>((ref) {
  throw UnimplementedError(
    'audioPlayerControllerProvider must be overridden at app bootstrap',
  );
});
