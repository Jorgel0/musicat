import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/audio/audio_providers.dart';
import 'package:musicat/features/settings/audio/presentation/sleep_timer_controller.dart';

import 'fakes/fake_audio_player_controller.dart';

void main() {
  late FakeAudioPlayerController audioController;
  late ProviderContainer container;

  setUp(() {
    audioController = FakeAudioPlayerController();
    container = ProviderContainer(
      overrides: [
        audioPlayerControllerProvider.overrideWithValue(audioController),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('start() marks the timer active with the requested duration', () {
    container
        .read(sleepTimerControllerProvider.notifier)
        .start(const Duration(minutes: 10));

    final state = container.read(sleepTimerControllerProvider);

    expect(state.isActive, isTrue);
    expect(state.remaining, const Duration(minutes: 10));
  });

  test('cancel() clears an active timer', () {
    final notifier = container.read(sleepTimerControllerProvider.notifier);
    notifier.start(const Duration(minutes: 10));

    notifier.cancel();

    expect(container.read(sleepTimerControllerProvider).isActive, isFalse);
  });

  test('pauses playback once the timer reaches zero', () async {
    container
        .read(sleepTimerControllerProvider.notifier)
        .start(const Duration(seconds: 2));

    await Future<void>.delayed(const Duration(milliseconds: 2200));

    expect(container.read(sleepTimerControllerProvider).isActive, isFalse);
    expect(audioController.calls, contains('pause'));
  });
}
