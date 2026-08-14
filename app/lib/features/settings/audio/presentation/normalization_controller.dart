import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/audio/audio_providers.dart';

const _enabledKey = 'volumeNormalizationEnabled';

/// Whether ReplayGain-based volume normalization is enabled. Defaults to
/// on — it's a no-op for files without ReplayGain tags, which covers most
/// Soulseek downloads, so there's no downside to leaving it on by default.
class NormalizationController extends Notifier<bool> {
  NormalizationController([this._initial = true]);

  final bool _initial;

  @override
  bool build() => _initial;

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await ref
        .read(audioPlayerControllerProvider)
        .setNormalizationEnabled(enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }
}

final normalizationControllerProvider =
    NotifierProvider<NormalizationController, bool>(
      NormalizationController.new,
    );

/// Loads the persisted setting, for overriding [normalizationControllerProvider]
/// at bootstrap before the first frame — same pattern as the theme
/// preferences.
Future<bool> loadNormalizationPreference() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_enabledKey) ?? true;
}
