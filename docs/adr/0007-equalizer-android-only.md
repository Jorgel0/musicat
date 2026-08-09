# 0007 — Equalizer via just_audio's built-in AndroidEqualizer; mono/stereo dropped

## Context
Fase 1.5 called for an equalizer and a mono/stereo toggle. The original
plan (see the phased roadmap) already expected the equalizer to need
Android-specific native code via `android.media.audiofx.Equalizer`
attached to ExoPlayer's `audioSessionId`, with Windows/Linux flagged as
"no direct system equivalent — evaluate as a dedicated spike."

While implementing this, two things became clear:

1. `just_audio` already ships `AndroidEqualizer`/`AudioPipeline` support
   built on top of `android.media.audiofx.Equalizer` — no custom Kotlin
   platform channel is needed at all. It's constructed once (as part of
   the `AudioPlayer`'s `audioPipeline`) and only activates once a track
   has loaded, at which point `AndroidEqualizerParameters` (band count,
   frequencies, dB range) becomes available from the real device.
2. Mono/stereo (force a stereo→mono downmix) has **no public Android SDK
   API** at all — verified directly by decompiling the real
   `android.jar` (API 36) for any `AudioManager` method mentioning
   mono/channel/downmix/balance: nothing exists. (An earlier assumption
   that `AudioManager.setMasterMono()` was usable was wrong — that
   method isn't present in the public SDK stub, meaning it's hidden/
   system-only.) A real implementation would require forking just_audio's
   native Android plugin to inject a custom ExoPlayer `AudioProcessor`
   into its audio pipeline — a much larger, riskier undertaking than the
   rest of Fase 1.5.

## Decision
- Ship the equalizer using `just_audio`'s built-in `AndroidEqualizer`,
  gated behind `Platform.isAndroid` in `MusicatAudioHandler`. Exposed
  through `AudioPlayerController` as engine-agnostic
  `EqualizerInfo`/`EqualizerBandInfo` types (never leaking `just_audio`
  types past the handler), with band gains and the enabled flag
  persisted via `shared_preferences` and restored once the equalizer
  activates.
- **Do not implement mono/stereo for now.** It's not a scope reduction
  for lack of trying — it was scoped, investigated, and found to require
  disproportionate effort (forking a third-party native plugin) for what
  the phased plan always treated as a nice-to-have. Revisit only if
  either (a) `just_audio` grows first-party support, or (b) it's worth
  scoping as its own dedicated spike with a real time budget.

## Consequences
- Equalizer is Android-only, same as originally planned; Linux/Windows
  show "not available on this platform" in Settings rather than a
  non-functional control.
- Verified end-to-end on a real device (Android 13): 5 real hardware
  bands (60/230/910/3600/14000 Hz), -15..15 dB range, enabling and
  per-band gain changes both confirmed via logs and a screenshot of the
  running app.
- The equalizer only becomes available once a track has been loaded at
  least once in the session (that's when just_audio activates the
  pipeline) — the Settings screen shows a prompt to play something first
  rather than hanging on an unresolved state.
