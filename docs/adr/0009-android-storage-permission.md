# 0009 — Android needs a real storage permission; the SAF folder picker's grant isn't enough

## Context
`LibraryScanner` (Fase 1) reads a folder with plain `dart:io`
(`Directory.list(recursive: true)`, `File.readAsBytes()` via `audiotags`),
the same code path on every platform. On Android, folders are chosen via
`file_picker`'s `getDirectoryPath()`, which uses the system Storage Access
Framework (SAF) document-tree picker.

While verifying loudness normalization (ADR 0008) on a real Android 13
device, adding a folder outside the app's own storage (`Download/...`)
consistently reported "Imported 0 track(s)." — silently, no exception
anywhere in logcat. Debug logging showed the picked path was correct and
`Directory(path).existsSync()` returned `true`, yet `dir.list()` still
yielded nothing.

Root cause: SAF's folder picker grants a `content://` URI permission,
usable only through `ContentResolver`/`DocumentFile` APIs. It does **not**
unlock raw filesystem access for `dart:io`, which opens files by path
directly and is subject to Android's scoped storage rules independent of
any SAF grant. The app's manifest declared no storage permission at all, so
raw folder listing outside the app's private storage silently returned
empty — confirmed by declaring `READ_MEDIA_AUDIO` and granting it via `adb
shell pm grant`, which immediately fixed the scan.

This had gone unnoticed through the rest of Fase 1 because every previous
real-device verification used test fixtures pushed directly into the app's
own private storage (`run-as ... cp`) specifically to route around an
earlier, related scoped-storage problem — which meant the actual
user-facing "pick any folder" flow had never been exercised end-to-end on
real hardware until now.

## Decision
- Declare `READ_MEDIA_AUDIO` (Android 13+) and `READ_EXTERNAL_STORAGE`
  (`maxSdkVersion="32"`, for older versions) in the manifest.
- Add `permission_handler` and request `Permission.audio` +
  `Permission.storage` together right before invoking the folder picker in
  `pickAndScanFolder`; proceed only if at least one resolves granted.
- **Not** building the originally-planned native `MediaStore` Kotlin
  channel for this. A runtime media permission plus the existing
  `dart:io`-based scanner is far less code, and is Google's own current
  recommendation for apps that need broad audio file access (see
  `permission_handler`'s README on `READ_MEDIA_AUDIO` vs.
  `MANAGE_EXTERNAL_STORAGE`). Revisit only if a real need for non-audio
  file access or finer-grained per-file access emerges.

## Consequences
- Real users adding any folder outside Musicat's own storage now see a
  normal Android runtime permission prompt the first time; declining it
  surfaces a message rather than a silent "Imported 0 track(s)."
- Verified end-to-end on the real Android 13 device: with the permission
  granted, the same `Download/...` folder that previously reported 0
  tracks imported both real fixture files correctly.
- Linux/Windows are unaffected — `Platform.isAndroid` gates the permission
  request, and `dart:io` folder access there was never restricted.
