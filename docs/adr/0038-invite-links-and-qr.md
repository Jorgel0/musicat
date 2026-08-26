# 0038 — Invite links and QR codes for pairing and joint playlists

## Context
Both of Fase 4's invite flows were pure manual copy-paste since they were
built (ADR 0026, 0028): pairing needs a friend's address *and* a
one-time code typed into two separate fields; joining a joint playlist
needs its id typed in. Flagged as an open gap in ADR 0035-0037. Jorge's
direction: build the full thing, including real Android deep linking (a
shared link opens the app and pre-fills the flow), not just an in-app QR
code. Built via `/dev-team` (a `frontend-dev` round — pure client-side,
no server changes, since everything an invite encodes already existed
and was already exchanged over the wire).

## Decision
- **One URI format, one parser** (`app/lib/core/invite/invite_uri.dart`),
  used by both the QR/share code and the deep-link handler so the shape
  is defined exactly once:
  - `musicat://friend?address=<host:port>&code=<pairing code>&name=<optional>`
  - `musicat://playlist?id=<playlist id>&name=<optional>`
  - A sealed `InvitePayload` (`FriendInvite`/`PlaylistInvite`) and a
    typed `InviteUriException` with plain, user-presentable messages.
- **QR generation** (`qr_flutter`) and **native share** (`share_plus`)
  on both the "Your invite" panel in the Add Friend sheet and the
  joint-playlist share-id dialog, alongside (not replacing) the existing
  copyable text.
- **QR scanning** (`mobile_scanner`), via one shared full-screen scanner
  (`qr_scanner_screen.dart`) both flows reuse — camera permission
  requested at point of use, same pattern as the existing folder-picker
  storage permission. **Android-only**: `mobile_scanner` has no
  Linux/Windows implementation, gated behind `qrScanningSupported`
  (`Platform.isAndroid`) rather than crashing on desktop.
- **A "paste an invite link" fallback** everywhere scanning is offered —
  runs the same parser on pasted text, so desktop (no camera, no OS
  deep-link registration either) still has a working, non-manual-typing
  path once a link exists in the clipboard by any means.
- **Real Android deep linking**: `musicat://` registered as a second
  `<intent-filter>` on `MainActivity` (custom scheme, so no App Links
  verification/`assetlinks.json` needed) plus `flutter_deeplinking_enabled`.
  A top-level go_router `redirect` intercepts the incoming URI, parses
  it, stashes the result in a new `pendingInviteProvider`, and redirects
  to `/friends` or `/playlists` — the landing screen notices the pending
  invite on its first frame and opens the relevant sheet pre-filled.
  Nothing auto-submits: redeeming a pairing code or joining a playlist
  still needs an explicit tap. A link that fails to parse is never
  silently dropped — it's surfaced as a SnackBar from `AppShell`.
  **Linux/Windows desktop deep-link registration is explicitly out of
  scope** (separate OS-level file-association config); QR/scan/paste all
  still work per-platform as described above.

## Consequences
- `dart format`/`flutter analyze`/`flutter test` all clean; app test
  count 125 → 159 (34 new: invite-URI build/parse round-trips and
  rejections, QR widgets rendering the exact expected encoded data,
  scan/paste pre-fill fed valid and invalid strings directly, the
  pending-invite hand-off including an "already joined → navigate
  straight there" case through a real `GoRouter`).
- A real bug caught by the new widget tests, not `flutter analyze`:
  `qr_flutter`'s `QrImageView` always wraps itself in a `LayoutBuilder`;
  placed directly inside an `AlertDialog` (which sizes content via
  `IntrinsicWidth`), this throws `LayoutBuilder does not support
  returning intrinsic dimensions` — a real crash the joint-playlist share
  dialog would have hit on first real use. Fixed by wrapping both
  `QrImageView` usages in a fixed-size `SizedBox`.
- `share_plus` pinned to `^12.0.2`, not the latest `^13.x`: `13.x`
  requires `win32 ^6.0.1`, conflicting with `file_picker ^11.0.3`'s
  `win32 ^5.9.0`. A conscious, documented choice, not an oversight —
  revisit alongside a future `file_picker` bump if ever needed.
- `mobile_scanner`'s own package `AndroidManifest.xml` already declares
  `android.permission.CAMERA` (merged in automatically by Gradle) — no
  need to redeclare it in the app's own manifest, confirmed by reading
  the plugin's manifest directly rather than assuming.
- Verified for real: `flutter analyze`/`flutter test` (159/159) run
  directly, plus a live `flutter run -d linux --release` smoke launch
  (clean build, no crash on startup or shutdown) to catch exactly the
  class of runtime-only failure the `QrImageView` bug above was. **Not**
  verified, and not practical in this environment: an actual Android
  device/emulator tapping a real `musicat://` link (cold and warm
  start), real camera scanning, real `share_plus` platform-channel
  behavior — the manifest XML and go_router wiring were reviewed against
  Flutter's documented deep-linking mechanism, not guessed, but the
  true end-to-end "tap a shared link, watch the app open pre-filled"
  path needs a real device.
- Next up, per plan: a `/dev-team` `bug-hunter` + `feedback-critic` QA
  pass on this feature specifically.
