# 0013 — Local slskd for auto-import; remote slskd stays manual-import

## Context
The original Fase 2 plan called for completed downloads to appear in the
library automatically, reusing Fase 1's import pipeline. Building this
against Jorge's real deployment (slskd on a separate Debian CT, reached
over the LAN) surfaced a real architectural constraint: **slskd's REST API
has no endpoint that serves a downloaded file's actual bytes.**
`FilesController` (`GET /api/v0/files/downloads/directories/...`) only
lists and deletes files on slskd's own disk — there is no
`GET .../files/downloads/{file}` or equivalent. This isn't a gap in our
own client; it's a real limit of the API surface slskd exposes, confirmed
by reading its full controller source, not inferred from docs.

Since Musicat has no native Soulseek protocol implementation of its own
(that's explicitly what slskd is for — see ADR 0004), a completed download
necessarily lands on whatever machine runs slskd. If that's a separate
device from wherever Musicat runs, there is currently no way to pull the
file's bytes back over the network without adding new infrastructure of
our own (a companion file-transfer service, reusing the SSH already on
that machine, etc.) — each with real downsides discussed and rejected
below.

## Decision
- **Ship auto-import only for the case where slskd runs on the same
  device as Musicat** — Linux/Windows desktop today, since slskd has no
  Android build. In that case the "transfer" is trivial: the file is
  already sitting in a real local folder the moment slskd finishes, so
  the existing `LibraryScanner.scanFolder()` (unchanged) is all that's
  needed — no file-transfer mechanism to build at all.
- **Detect the downloads directory from slskd itself, rather than asking
  the user to type/pick it** — `SoulseekClient.getDownloadsDirectory()`
  reads `directories.downloads` off `GET /api/v0/options` (a read-only,
  always-available endpoint; no `RemoteConfiguration` flag needed, unlike
  the `PATCH /api/v0/options` overlay endpoint, which only covers
  Soulseek listen IP/port at runtime and can't set the downloads directory
  at all — it's fixed at slskd's own startup). `DownloadsController` fetches
  this once per session and only acts on it if
  `Directory(path).existsSync()` is true *on this device* — the one signal
  that actually tells us slskd is local, without any manual "yes I'm
  running it locally" toggle. It tracks which transfer ids have already
  been seen as `succeeded`; whenever a poll finds newly-succeeded ones and
  the directory exists here, it rescans that folder once.
  - **First attempt was a manual `SoulseekConfig.localDownloadsFolder`
    text field with a folder picker** — reverted after a real, live bug:
    Jorge picked his general music library folder (`~/Musica`, the
    Spanish-locale XDG default) instead of slskd's actual configured
    downloads folder (`~/Music/SoulseekDownloads`, created during this
    same setup) — two folders that look almost identical, typed/picked
    independently of what slskd was actually told to use. Auto-import
    silently scanned the wrong (but real, existing) folder — no error,
    just the right song never showing up. Asking slskd directly removes
    the chance of that mismatch entirely, and needed no new user-facing
    setting at all.
- **Do not** solve this for a remote slskd (like the Debian CT) in this
  slice. Two ways to bridge that gap were considered and explicitly
  rejected for now:
  - A dedicated lightweight file server on the remote host, purely to
    serve the downloads folder over HTTP. Rejected for now, not because
    it doesn't work, but because Jorge's actual goal is for the whole
    download pipeline to work from the device running Musicat without a
    server dependency at all — this would still leave Android depending
    on a remote host indefinitely.
  - SFTP over the SSH already running on that host (no new service).
    Rejected on security grounds: it would mean shipping an SSH
    credential with effectively root-level access to the whole host
    inside a mobile app, a much larger blast radius than the one thing
    that credential is actually needed for (reading one folder).
- **The real fix for Android — a native Soulseek client in Dart, so the
  phone is its own peer with no backend at all — is deferred to the
  future phase the original plan already reserved for it** (see the
  phased roadmap's "cliente Soulseek nativo en Android," with its own
  named risks: undocumented protocol, mobile NAT traversal, Android
  background-execution limits). Search/download/queue against a remote
  slskd (the Debian CT) keep working exactly as already shipped for
  Android in the meantime; only auto-import is unavailable there — the
  existing manual "Add folder" flow is the fallback.

## Consequences
- Real local slskd was installed and verified on the Linux desktop (the
  native `linux-x64` release binary, no Docker) as part of validating this
  decision, running as its own Soulseek account so it doesn't conflict
  with logins from the Debian CT's instance.
- Desktop users pointing Musicat at a local slskd get the fully
  offline-capable, fully-on-device experience Jorge asked for, today.
- Android users keep the Debian-CT-based flow already shipped (search,
  download, queue, cancel) with one known gap — no auto-import — clearly
  scoped to a future phase rather than worked around with something
  weaker.
- `scanFolder()` re-reads every file in the folder on each newly-succeeded
  transfer, not just the new one — acceptable for a small,
  downloads-only folder, but would need to become more targeted if this
  pattern were ever reused against a large, general-purpose watched
  folder.
