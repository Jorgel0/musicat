# Contributing to Musicat

Thanks for your interest in contributing!

## Development setup

- Flutter (stable channel) — see `app/pubspec.yaml` for the minimum SDK
  constraint.
- Android SDK (cmdline-tools + platform-tools) for the Android target.
- On Linux, the desktop target needs `clang`, `cmake`, `ninja`, `pkg-config`,
  and GTK 3 development headers, plus `libmpv` (e.g. `pacman -S mpv` on
  Arch, `apt install libmpv-dev` on Debian/Ubuntu) — audio playback on
  Linux runs through `media_kit`/libmpv, since `just_audio` has no native
  Linux backend of its own. See `docs/adr/0006-just-audio-media-kit.md`.

```
cd app
flutter pub get
flutter test
flutter run -d linux   # or -d <android-device-id>
```

## Before opening a merge/pull request

- `dart format --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`

All of the above run in CI; a PR won't be mergeable until they pass.

## Code style

- English for all code, comments, and documentation.
- Follow the existing feature-first structure under `app/lib/features/`:
  each feature has its own `domain/`, `data/`, and `presentation/`
  subfolders. See `docs/architecture.md` for the reasoning.
- State management uses Riverpod (`riverpod_lint` runs in CI and will flag
  common mistakes).

## Testing without a Soulseek account

Soulseek integration talks to a `slskd` instance through the `SoulseekClient`
interface (`app/lib/core/network/soulseek/`). Tests and local development
against that layer use a mocked HTTP client — you do not need real Soulseek
credentials to contribute to search/download features.
