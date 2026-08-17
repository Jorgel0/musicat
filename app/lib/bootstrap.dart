import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'app.dart';
import 'core/audio/audio_providers.dart';
import 'core/audio/audio_service_bootstrap.dart';
import 'core/design_system/theme.dart';
import 'features/friends/presentation/musicat_server_config_controller.dart';
import 'features/settings/audio/presentation/normalization_controller.dart';
import 'features/settings/soulseek/presentation/soulseek_config_controller.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  // just_audio has no native Linux/Windows implementation of its own; this
  // registers media_kit (libmpv) as the backend on those two platforms only
  // — Android/iOS/macOS keep using just_audio's own native code untouched.
  // See docs/adr/0006-just-audio-media-kit.md.
  JustAudioMediaKit.ensureInitialized();
  final audioHandler = await initAudioService();
  final themePreferences = await loadThemePreferences();
  final normalizationEnabled = await loadNormalizationPreference();
  // The handler defaults to normalization on; bring it in line with the
  // persisted preference before the first track ever plays.
  await audioHandler.setNormalizationEnabled(normalizationEnabled);
  final soulseekConfig = await loadSoulseekConfigPreference();
  final musicatServerConfig = await loadMusicatServerConfigPreference();
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
        normalizationControllerProvider.overrideWith(
          () => NormalizationController(normalizationEnabled),
        ),
        soulseekConfigControllerProvider.overrideWith(
          () => SoulseekConfigController(soulseekConfig),
        ),
        musicatServerConfigControllerProvider.overrideWith(
          () => MusicatServerConfigController(musicatServerConfig),
        ),
      ],
      child: const MusicatApp(),
    ),
  );
}
