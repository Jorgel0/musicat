# 0001 — Flutter as the multiplatform framework

## Context
Musicat needs a single codebase covering Android (primary), Windows, and
Linux desktop.

## Decision
Use Flutter. Its Linux desktop support is meaningfully more mature than
React Native's (which has no real Linux story), it shares one Dart codebase
across all three targets, and its plugin ecosystem covers background audio,
platform channels, and UI theming well enough for a music player.

## Consequences
- Android-specific integrations (MediaStore, `AudioEffect`/`Equalizer`) go
  through platform channels written in Kotlin.
- Windows/Linux system media integration (SMTC, MPRIS) relies on younger,
  less complete packages than the Android side — see ADR 0002 and
  `docs/architecture.md` Phase 1.5.
