# Musicat — architecture overview

## Goals

- Single Flutter codebase for Android (primary target), Windows, and Linux.
- A local-first music player: downloaded music always works offline.
- Soulseek search/download, and later federated friend-to-friend music and
  playlist sharing, without depending on a third-party central server.

## Structure

Musicat uses a **feature-first** layout: each feature under `app/lib/features/`
owns its own `domain/` (entities, repository interfaces, use cases), `data/`
(repository implementations), and `presentation/` (Riverpod providers,
screens, widgets). This keeps a feature's full vertical slice in one place,
which matters for an open-source project where external contributors pick up
one feature at a time — it keeps pull requests small and self-contained.

Cross-cutting infrastructure lives under `app/lib/core/`:

- `core/audio/` — `AudioPlayerController`, the interface the rest of the app
  talks to for playback. The concrete implementation wraps `just_audio` +
  `audio_service`.
- `core/database/` — the Drift (`AppDatabase`) schema: the single source of
  truth for the local catalog, playlists, and settings.
- `core/network/soulseek/` — the `SoulseekClient` interface. This is
  deliberately abstracted so the concrete backend can change without
  touching the rest of the app:
  - Phase 2: `slskd/` — talks to a self-hosted `slskd` instance over REST.
  - Phase 3: `musicat_server/` — talks to the self-hosted Musicat Server,
    which itself wraps `slskd`.
  - Future phase: a native Dart Soulseek client, so a device (e.g. Android)
    can act as an autonomous peer without depending on a fixed backend.
- `core/network/social/` — placeholder for the Phase 4 federation interface
  (friend-to-friend, backend-to-backend).

## Why this shape

The Soulseek and social/federation layers are the parts of Musicat most
likely to change backend strategy over time (see the phased roadmap below).
Keeping them behind interfaces from day one means the player, library, and
playlists — which are Phase 1 concerns — never need to know or care how a
track ended up on disk or who it's shared with.

## Phased roadmap

See the original planning document for full detail on each phase's scope and
"done" criteria. Summary:

- **Phase 0** — repo setup, licensing, CI, Flutter scaffold (this phase).
- **Phase 1** — local MVP player: library scan, playlists, full-screen now
  playing, shuffle/repeat, queue.
- **Phase 1.5** — mono/stereo, equalizer, sleep timer, loudness
  normalization. Split out because, with `just_audio`, equalizer and
  mono/stereo require platform-specific native code (Android via
  `android.media.audiofx.Equalizer`); Windows/Linux support for those two is
  not guaranteed and may end up Android-only.
- **Phase 2** — Soulseek search/download via a self-hosted `slskd` backend.
- **Phase 3** — Musicat Server: a self-hosted node (AGPL-3.0) that wraps
  `slskd` and exposes a stable API, laying the groundwork for federation.
- **Phase 4** — federated friend-sharing: two self-hosted Musicat Server
  nodes talk directly to each other, no third-party central server.
- **Future** — native Soulseek client in Dart, so mobile devices can act as
  autonomous peers.

## Architecture Decision Records

See `docs/adr/` for the reasoning behind specific technical choices
(state management, local database, networking abstraction, etc.).
