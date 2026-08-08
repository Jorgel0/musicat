# 0002 — Riverpod for state management

## Context
The app needs a state management approach that scales across many features
(player, library, playlists, search, downloads, settings, friends) and is
approachable for external open-source contributors.

## Decision
Use `flutter_riverpod` with `riverpod_annotation`/`riverpod_generator`.
One `Notifier`/`AsyncNotifier` per main use case (e.g. `PlaybackNotifier`,
`LibraryNotifier`, `SoulseekSearchNotifier`).

## Consequences
- Dependencies (e.g. `SoulseekClient`, `AudioPlayerController`) are injected
  via providers, which makes overriding them with fakes in tests
  straightforward and keeps domain code testable without a `BuildContext`.

## Update (Phase 0, 2026-08)
`riverpod_generator`/`riverpod_lint` are not used yet: as of this writing,
`riverpod_lint`'s latest release pins an exact `riverpod` patch version that
lags behind the `riverpod 3.4.x` line `flutter_riverpod` currently resolves
to, and conflicts with the `test`/`flutter_test` dependency tree bundled with
the current Flutter SDK. Providers are hand-written (`Provider`/`Notifier`/
`AsyncNotifier` without `@riverpod` codegen) until that lag resolves; revisit
adding codegen + lint once the versions line up, rather than pinning
`riverpod` to an older line just to unblock tooling.
