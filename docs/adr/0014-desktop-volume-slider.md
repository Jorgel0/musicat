# 0014 — In-app volume slider, desktop only

## Context
Jorge asked for a volume slider on the Now Playing screen for the PC
builds (Linux/Windows). Android already has this covered by the hardware
volume keys/system volume, the way essentially every Android media app
works — an in-app slider there would just be a second, redundant volume
control. Desktop doesn't have an equivalent expectation baked into the
platform the same way, so a per-app slider is the normal pattern there
(most desktop media players have one).

The playback engine already calls `_player.setVolume()` for one reason —
ReplayGain-based normalization (ADR 0008), toggled automatically per
track. Adding a second, independent volume control risks the two
fighting over the same knob if not designed together up front.

## Decision
- `AudioPlayerController` gains `volumeStream`/`setVolume(double)` for a
  user-set level from 0.0–1.0, independent of ReplayGain.
- `MusicatAudioHandler` keeps both values separately (`_userVolume`,
  `_replayGainVolume`) and always applies their **product** to the
  player: moving the slider doesn't erase whatever ReplayGain is doing
  for the current track, and a track change recomputing ReplayGain
  doesn't reset the user's slider position.
- The slider itself is gated to `Platform.isLinux || Platform.isWindows`
  in the Now Playing screen — not built as a generic "volume control"
  that happens to be hidden on Android, but explicitly scoped as a
  desktop-only affordance from the start, matching how the equalizer
  (ADR 0007) is scoped the other way (Android-only).
- Not persisted across app restarts — treated like a live control (closer
  to a physical volume knob than a saved preference), consistent with not
  adding a setting the user didn't ask for.

## Consequences
- No behavior change on Android: `_userVolume` defaults to 1.0 and
  nothing in the Android UI ever calls `setVolume`, so ReplayGain-only
  behavior there is unaffected.
- Any future platform-specific playback feature should follow this same
  pattern of gating in the UI layer rather than in the engine, keeping
  `AudioPlayerController` platform-agnostic.
