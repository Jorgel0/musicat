import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/audio/audio_providers.dart';
import 'package:musicat/features/settings/audio/presentation/normalization_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_controller.dart';

void main() {
  late FakeAudioPlayerController audioController;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    audioController = FakeAudioPlayerController();
    container = ProviderContainer(
      overrides: [
        audioPlayerControllerProvider.overrideWithValue(audioController),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('defaults to enabled', () {
    expect(container.read(normalizationControllerProvider), isTrue);
  });

  test('setEnabled updates state, the engine, and persists it', () async {
    await container
        .read(normalizationControllerProvider.notifier)
        .setEnabled(false);

    expect(container.read(normalizationControllerProvider), isFalse);
    expect(audioController.calls, contains('setNormalizationEnabled'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('volumeNormalizationEnabled'), isFalse);
  });

  test('loadNormalizationPreference defaults to true when unset', () async {
    expect(await loadNormalizationPreference(), isTrue);
  });

  test('loadNormalizationPreference returns the persisted value', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('volumeNormalizationEnabled', false);

    expect(await loadNormalizationPreference(), isFalse);
  });
}
