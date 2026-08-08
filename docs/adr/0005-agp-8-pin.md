# 0005 — Pin Android Gradle Plugin below 9

## Context
`flutter create` (Flutter 3.44.9, August 2026) defaulted this project to
AGP 9.0.1, which changed the default to Flutter's "built-in Kotlin" Gradle
support and removed the old world where individual plugins self-apply the
Kotlin Gradle Plugin (KGP).

In practice this broke both native-dependency plugins we use:
- `file_picker` 11.0.3 deliberately skips self-applying KGP under AGP 9+,
  assuming built-in Kotlin will compile its Kotlin sources instead. With
  `android.builtInKotlin=false` (the other default the template set), its
  Kotlin plugin class is simply never compiled → "cannot find symbol"
  linking `GeneratedPluginRegistrant`.
- `audiotags` 1.4.5 unconditionally does `apply plugin: 'kotlin-android'`
  regardless of AGP version — a Flutter built-in-Kotlin build (i.e.
  `android.builtInKotlin=true`) hard-fails on any plugin that still does
  this by design, since Flutter's tooling now forbids it.

There is no single `android.builtInKotlin` value under AGP 9 that satisfies
both plugins at once: one requires it on, the other requires it off.

## Decision
Pin `com.android.application` to `8.11.1` and the Gradle wrapper to
`8.14.3` (settings.gradle.kts / gradle-wrapper.properties) — the newest
patch versions Flutter's own tooling still recommends staying above,
without crossing into AGP 9 — and keep `android.builtInKotlin=false`.
Under AGP < 9, `file_picker`'s
`isAgp9OrAbove` check is false so it self-applies KGP like it always did,
and `audiotags`'s unconditional self-apply works exactly as it was written
against. This is the version combination most of the current plugin
ecosystem still assumes.

## Consequences
- We're intentionally behind the newest AGP/Gradle rather than chasing
  each dependency's built-in-Kotlin migration individually.
- Revisit this once `audiotags` (tracked in issue #1 for its separate
  Windows build failure too) either migrates to built-in Kotlin or gets
  replaced behind the `AudioTagReader` interface — at that point AGP can
  move back to 9+.
