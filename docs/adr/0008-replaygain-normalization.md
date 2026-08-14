# 0008 — Volume normalization via ReplayGain tags, using a second tag-reading dependency

## Context
Fase 1.5 called for loudness normalization, scoped from the start (see the
phased roadmap) as "if the file carries ReplayGain tags, adjust
`player.setVolume()` accordingly; no tags means no normalization in v1" —
explicitly ruling out real-time loudness analysis as out of scope.

`audiotags`, the tag-reading dependency already used for the library
scanner, exposes a fixed, typed `Tag` (title/artist/album/...) with no
access to raw/custom frames — it cannot read ReplayGain at all, since
those are stored as a raw ID3v2 `TXXX` frame (MP3) or a Vorbis comment
(FLAC/OGG/Opus), not a standard tag field.

`audio_metadata_reader` (pure Dart) does expose this: `Mp3Metadata` has a
`customMetadata` map covering arbitrary `TXXX` frames, and `VorbisMetadata`
has dedicated `replayGainTrackGain`/`replayGainAlbumGain` fields.

## Decision
- Add `audio_metadata_reader` as a **second, narrowly-scoped** dependency,
  used only by `core/audio/replay_gain_reader.dart` to read a track's
  ReplayGain track-gain tag. Do **not** replace `audiotags` — swapping the
  library the whole scanner pipeline depends on is a bigger, riskier
  change than this slice needs, and `audiotags`'s typed fields remain a
  better fit for the scanner's needs.
- Convert the dB tag value to a linear volume multiplier
  (`10^(gainDb/20)`), clamped to `[0.0, 1.0]` — never boost above the
  source volume (a positive ReplayGain tag would mean raising the volume,
  which risks clipping and isn't loudness *normalization* so much as
  amplification).
- Apply it via `AudioPlayerController.setVolume()`-equivalent
  (`_player.setVolume()` inside `MusicatAudioHandler`) every time the
  current track changes, gated by a persisted `normalizationEnabled` flag
  exposed through Settings (default **on** — it's a no-op for files
  without the tag, which is the common case for Soulseek downloads, so
  there's no downside to leaving it enabled).
- No peak/headroom handling: a track whose gain tag under-corrects for
  true peak level may still clip. Out of scope for v1, same as the
  original plan's framing.

## Consequences
- Works identically on Android/Linux/Windows — `setVolume()` is a
  cross-platform just_audio API, unlike the equalizer (ADR 0007).
- Only has an audible effect on files that actually carry ReplayGain tags;
  most Soulseek-sourced downloads won't, and will play at full volume
  exactly as before this change.
- Two tag-reading libraries now coexist in the codebase for different
  purposes (`audiotags` for the scanner's typed metadata,
  `audio_metadata_reader` for ReplayGain only) — a future consolidation is
  possible but not warranted by this slice alone.
