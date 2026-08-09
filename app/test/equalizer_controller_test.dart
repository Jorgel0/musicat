import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/audio/audio_providers.dart';
import 'package:musicat/features/settings/audio/presentation/equalizer_controller.dart';
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

  test('is null when the platform does not support an equalizer', () async {
    audioController.equalizerSupported = false;

    final info = await container.read(equalizerControllerProvider.future);

    expect(info, isNull);
  });

  test('exposes the bands reported by the controller', () async {
    final info = await container.read(equalizerControllerProvider.future);

    expect(info, isNotNull);
    expect(info!.bands, hasLength(5));
    expect(info.bands.every((b) => b.gainDb == 0), isTrue);
  });

  test('setBandGain updates state and persists the value', () async {
    await container.read(equalizerControllerProvider.future);

    await container
        .read(equalizerControllerProvider.notifier)
        .setBandGain(2, 6.0);

    final info = container.read(equalizerControllerProvider).value;
    expect(info!.bands[2].gainDb, 6.0);
    expect(audioController.equalizerBandGains[2], 6.0);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('equalizerBandGain_2'), 6.0);
  });

  test('setEnabled updates state and persists the value', () async {
    await container.read(equalizerControllerProvider.future);

    await container.read(equalizerControllerProvider.notifier).setEnabled(true);

    expect(container.read(equalizerControllerProvider).value!.enabled, isTrue);
    expect(audioController.equalizerEnabled, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('equalizerEnabled'), isTrue);
  });

  test('restores persisted band gains on the next build', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('equalizerBandGain_1', -4.0);
    await prefs.setBool('equalizerEnabled', true);

    final info = await container.read(equalizerControllerProvider.future);

    expect(info!.enabled, isTrue);
    expect(info.bands[1].gainDb, -4.0);
    // The persisted values should have been re-applied to the engine too.
    expect(audioController.equalizerBandGains[1], -4.0);
    expect(audioController.equalizerEnabled, isTrue);
  });
}
