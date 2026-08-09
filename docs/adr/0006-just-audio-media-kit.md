# 0006 — just_audio has no Linux/Windows backend of its own

## Context
`just_audio` 0.10.6 only ships a native platform implementation for
Android, iOS, macOS, and web (see its `pubspec.yaml`'s
`flutter.plugin.platforms` — there is no `linux` or `windows` entry, and no
`default_package` fallback for either). On desktop Linux this fails at
runtime, not at build time: the app compiles, but the first
`AudioPlayer.setAudioSources()` call throws
`MissingPluginException(No implementation found for method init on
channel com.ryanheise.just_audio.methods)`, because
`generated_plugin_registrant.cc` has no Linux plugin to register — there
simply isn't one to find. This was caught by a manual smoke run
(`lib/dev_playback_smoke.dart`, not part of the app) rather than by
`flutter analyze`/`flutter test`, since neither exercises the real native
plugin registration (the same category of gap that let the Windows
`audiotags` bug and the AGP 9 conflict through — see issue #1 and ADR
0005).

## Decision
Add `just_audio_media_kit` (community package, MIT), which registers
[`media_kit`](https://pub.dev/packages/media_kit) (libmpv-based) as
`just_audio`'s backend on Linux and Windows only. Call
`JustAudioMediaKit.ensureInitialized()` once in `bootstrap.dart`, before
`initAudioService()` creates the first `AudioPlayer`. Its defaults
(`linux: true, windows: true, android/iOS/macOS: false`) are exactly what
we want, so no explicit platform flags are passed — Android, iOS, and
macOS keep using `just_audio`'s own native code, untouched.

## Consequences
- **New runtime dependency on Linux: system `libmpv`.** Unlike
  `media_kit_libs_windows_audio` (which bundles the required DLLs),
  `media_kit_libs_linux` does not bundle `libmpv` — it expects the distro
  to provide it (e.g. `pacman -S mpv` on Arch/CachyOS, `apt install
  libmpv-dev` on Debian/Ubuntu). Without it, `JustAudioMediaKit
  .ensureInitialized()` throws immediately with a message naming the
  missing library. This needs a mention in the README's Linux setup
  instructions, and will need real handling (bundle, or a first-run check
  with a clear error) once Musicat is packaged for end users (Flatpak/
  AppImage/deb) — tracked as a follow-up, not solved here.
- Windows gets `media_kit_libs_windows_audio`, which does bundle its
  native libraries, so no equivalent manual step is needed there.
- Revisit this if `just_audio` ever ships first-party Linux/Windows
  support, or if a Linux packaging format requires vendoring `libmpv`
  directly instead of relying on the system package.
