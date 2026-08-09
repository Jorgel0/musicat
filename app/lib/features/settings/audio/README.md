# features/settings/audio

Phase 1.5.

- ✅ Sleep timer (`presentation/sleep_timer_controller.dart`), pure Dart,
  all platforms.
- ✅ Equalizer (`presentation/equalizer_controller.dart` +
  `equalizer_screen.dart`), Android only — see ADR 0007 for why, and for
  why mono/stereo was dropped rather than half-implemented.
- ⏳ Loudness normalization — not started yet.
