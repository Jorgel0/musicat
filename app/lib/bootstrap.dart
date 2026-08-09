import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'app.dart';
import 'core/audio/audio_providers.dart';
import 'core/audio/audio_service_bootstrap.dart';
import 'core/design_system/theme.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  // just_audio has no native Linux/Windows implementation of its own; this
  // registers media_kit (libmpv) as the backend on those two platforms only
  // — Android/iOS/macOS keep using just_audio's own native code untouched.
  // See docs/adr/0006-just-audio-media-kit.md.
  JustAudioMediaKit.ensureInitialized();
  final audioHandler = await initAudioService();
  final themePreferences = await loadThemePreferences();
  runApp(
    ProviderScope(
      overrides: [
        audioPlayerControllerProvider.overrideWithValue(audioHandler),
        themeModeProvider.overrideWith(
          () => ThemeModeController(themePreferences.themeMode),
        ),
        accentColorProvider.overrideWith(
          () => AccentColorController(themePreferences.accentColor),
        ),
      ],
      child: const MusicatApp(),
    ),
  );
}
