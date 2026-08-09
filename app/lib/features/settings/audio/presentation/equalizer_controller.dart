import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/audio/audio_player_controller.dart';
import '../../../../core/audio/audio_providers.dart';
import '../../../../core/audio/equalizer_info.dart';

const _enabledKey = 'equalizerEnabled';
const _gainKeyPrefix = 'equalizerBandGain_';

/// `null` (once loaded) means the equalizer isn't available yet — either
/// unsupported on this platform, or no track has been loaded for the
/// engine to attach the effect to.
class EqualizerController extends AsyncNotifier<EqualizerInfo?> {
  @override
  Future<EqualizerInfo?> build() async {
    final controller = ref.watch(audioPlayerControllerProvider);
    final info = await controller.getEqualizerInfo();
    if (info == null) return null;
    return _applyPersistedSettings(controller, info);
  }

  Future<EqualizerInfo> _applyPersistedSettings(
    AudioPlayerController controller,
    EqualizerInfo info,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final savedEnabled = prefs.getBool(_enabledKey);
    if (savedEnabled != null && savedEnabled != info.enabled) {
      await controller.setEqualizerEnabled(savedEnabled);
    }
    final bands = <EqualizerBandInfo>[];
    for (final band in info.bands) {
      final savedGain = prefs.getDouble('$_gainKeyPrefix${band.index}');
      if (savedGain != null && savedGain != band.gainDb) {
        await controller.setEqualizerBandGain(band.index, savedGain);
        bands.add(
          EqualizerBandInfo(
            index: band.index,
            centerFrequencyHz: band.centerFrequencyHz,
            gainDb: savedGain,
          ),
        );
      } else {
        bands.add(band);
      }
    }
    return EqualizerInfo(
      enabled: savedEnabled ?? info.enabled,
      minDecibels: info.minDecibels,
      maxDecibels: info.maxDecibels,
      bands: bands,
    );
  }

  Future<void> setEnabled(bool enabled) async {
    final current = state.value;
    if (current == null) return;
    await ref.read(audioPlayerControllerProvider).setEqualizerEnabled(enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    state = AsyncData(
      EqualizerInfo(
        enabled: enabled,
        minDecibels: current.minDecibels,
        maxDecibels: current.maxDecibels,
        bands: current.bands,
      ),
    );
  }

  Future<void> setBandGain(int bandIndex, double gainDb) async {
    final current = state.value;
    if (current == null) return;
    await ref
        .read(audioPlayerControllerProvider)
        .setEqualizerBandGain(bandIndex, gainDb);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('$_gainKeyPrefix$bandIndex', gainDb);
    state = AsyncData(
      EqualizerInfo(
        enabled: current.enabled,
        minDecibels: current.minDecibels,
        maxDecibels: current.maxDecibels,
        bands: [
          for (final band in current.bands)
            band.index == bandIndex
                ? EqualizerBandInfo(
                    index: band.index,
                    centerFrequencyHz: band.centerFrequencyHz,
                    gainDb: gainDb,
                  )
                : band,
        ],
      ),
    );
  }
}

final equalizerControllerProvider =
    AsyncNotifierProvider<EqualizerController, EqualizerInfo?>(
      EqualizerController.new,
    );
