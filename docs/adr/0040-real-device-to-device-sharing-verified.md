# 0040 — Real device-to-device sharing verified through the actual app UI

## Context
Every prior "real" verification of Fase 4 (federation, sharing, the
relay, the invite/QR feature) went through throwaway scripts driving
`FederationClient`/`SharingClient` directly over HTTP, or through
`bin/server.dart` alone — never through two genuine, separate physical
devices both running the actual Musicat app UI. Jorge asked to close
that gap directly: pair two real devices and send a real song, doing
everything through the app as an actual user would.

## Setup
- **Device A**: this PC (Linux desktop), running both the Musicat app
  (`flutter run -d linux`) and its own Musicat Server (`dart run
  bin/server.dart`, port 8080), on the home LAN (`192.168.1.142`).
- **Device B**: a second Android phone (not the one used in ADR
  0032/0035's mobile-data tests), running the Musicat app as a sideloaded
  debug APK (`flutter build apk --debug`, installed manually since USB
  debugging couldn't be gotten working on that device this session — see
  Consequences) and its own Musicat Server in Termux, same as prior
  device-to-device tests, on the same home LAN (`192.168.1.138`).
- Both devices' local firewalls needed explicit allowances: this PC runs
  `ufw`, which silently drops unsolicited incoming connections by
  default — both the temporary APK-transfer HTTP server (port 8765) and
  the Musicat Server port itself (8080) needed `ufw allow` rules before
  either direction of the LAN traffic this test needed (APK download,
  peer-to-peer pairing/sharing calls, which go directly from the calling
  device's *app* to the target's server, not proxied) could get through.
- No relay involved — same-LAN direct reachability, deliberately simpler
  than ADR 0032/0035's cross-network scenario, to isolate this test to
  the app-and-storage layer rather than networking.

## What was tested, and the result
1. **Pairing via the new QR invite feature (ADR 0038/0039), for the
   first time on real hardware**: generated an invite (with its QR code)
   on the PC, scanned it with the second phone's camera — succeeded,
   registering the phone as the PC's trusted friend. Then the reverse
   (phone generates, PC redeems) to complete mutual trust. Both
   directions worked correctly through the real UI, including the
   single-use-code enforcement behaving exactly as designed (a reused
   code correctly 403s — briefly looked like a bug when the *result* of
   a first, successful redeem wasn't obviously reflected in the
   redeeming device's own friend list, until the one-directional nature
   of `addFriend` was worked through).
2. **Sharing and downloading a real file, phone → PC**: succeeded, after
   finding and fixing one genuine environmental issue (below) — the file
   ends up on the PC, downloaded byte-correctly through the real
   `SharingClient`/production download path (not a script).

## A real finding: Termux needs its own storage permission
The first download attempt failed with `SharingClientException(502,
Friend unreachable: ClientException: Connection closed before full
header was received, ...)`. The phone's own server log (`bin/server.dart`
running in Termux) showed the real cause directly:

```
PathAccessException: Cannot open file, path =
'/storage/emulated/0/Music/Kase.O - El Gordo Que la Pisa Bien.flac'
(OS Error: Permission denied, errno = 13)
```

Termux and the Musicat app are **separate Android apps with separate
storage sandboxes**. The Musicat app can read the file (it's in its own
scanned library — via whatever storage permission it was granted, e.g.
`READ_MEDIA_AUDIO`), but the Musicat *Server* process, running as
Termux's own UID, has no access to that path at all under Android's
scoped storage rules — a permission Android enforces per-app, not
per-file. Fixed by granting Termux full file access (Settings → Apps →
Termux → Permissions → "All files access"); the same download succeeded
immediately afterward with no code changes.

This is architecturally real, not a one-off glitch: **any current
Termux-hosted Musicat Server will hit this for any file outside its own
sandbox**, on any Android version enforcing scoped storage. It's the
concrete, first-hand version of the exact risk already flagged
(hypothetically) in the plan's "Fase futura: Musicat Server autoalojado
en el propio dispositivo" section — a separate-process server on Android
fundamentally cannot share arbitrary files with the app that manages
them unless it's granted the same (or broader) storage access, which
isn't automatic and isn't obvious to a new user setting this up.

## Consequences
- Fase 4's core promise — pair two real devices via the real UI, share a
  real song, download it — is now verified end to end through the
  *actual app*, not a script, for the first time.
- **Not a code bug, nothing to fix in `server/` or `app/`** — this is
  purely an Android permissions/deployment concern specific to running
  Musicat Server inside Termux as a separate app. Worth a line in a
  future self-hosting/Termux setup doc once one exists: grant Termux
  "All files access" before relying on it to serve shared music.
  Reinforces the case for the not-yet-started "Musicat Server
  autoalojado en el propio dispositivo" idea in the plan — an in-process
  server sharing the app's own storage permissions would sidestep this
  category of problem entirely, at least on Android.
- USB debugging couldn't be gotten working on the second phone this
  session (`lsusb` never saw it at the hardware level even after
  confirming Developer Options/USB debugging were on — most likely a
  charge-only cable or a bad port, not investigated further since
  sideloading a debug APK over the LAN was a fast enough workaround).
  Worth trying a different cable next time if `flutter run -d <device>`
  access to that phone is wanted again.
