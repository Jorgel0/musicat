import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/audio/audio_providers.dart';

class SleepTimerState {
  const SleepTimerState({this.remaining});

  final Duration? remaining;

  bool get isActive => remaining != null;
}

class SleepTimerController extends Notifier<SleepTimerState> {
  Timer? _ticker;

  @override
  SleepTimerState build() {
    ref.onDispose(() => _ticker?.cancel());
    return const SleepTimerState();
  }

  void start(Duration duration) {
    _ticker?.cancel();
    state = SleepTimerState(remaining: duration);
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = state.remaining;
      if (remaining == null) {
        timer.cancel();
        return;
      }
      final next = remaining - const Duration(seconds: 1);
      if (next <= Duration.zero) {
        timer.cancel();
        state = const SleepTimerState();
        ref.read(audioPlayerControllerProvider).pause();
      } else {
        state = SleepTimerState(remaining: next);
      }
    });
  }

  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    state = const SleepTimerState();
  }
}

final sleepTimerControllerProvider =
    NotifierProvider<SleepTimerController, SleepTimerState>(
      SleepTimerController.new,
    );
