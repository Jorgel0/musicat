# 0028 — App-side Friends section

## Context
Phase 4's federation backend (ADR 0019-0027) had no app UI yet. Jorge was
explicit about where it should live: "Pantalla de ajustes no, un apartado
de amigos" — not a Settings sub-screen, a dedicated top-level section,
same standing as Library/Search/Downloads/Playlists/Settings.

Federation is a distinct capability from the existing Soulseek
integration even though both ultimately point at the same running
Musicat Server instance — a device could run Musicat Server purely for
Soulseek and never configure friends, or vice versa. That argued for a
separate `MusicatServerConfig` (host/port to reach *this device's own*
server, plus the public address to give a friend) rather than reusing
`SoulseekConfig`.

## Decision
- `MusicatServerConfig{host, port, myPublicAddress}`
  (`features/friends/domain/`), persisted via `SharedPreferences` through
  `MusicatServerConfigController`, mirroring `SoulseekConfigController`'s
  established pattern exactly.
- `FederationClient` (`core/network/federation/`) wraps `/api/v1/node`,
  `/api/v1/federation/friends` (list/status/remove), and
  `/api/v1/federation/pairing-codes` (generate) — all against *this
  device's own* server. `addFriend()` is the one exception: it targets
  the **friend's** server directly, since redeeming a pairing code is
  inherently a call to whoever issued it. Pairing is therefore two-sided
  by construction — each person redeems the *other's* code on their own
  device against the *other's* server — so there's no local-call special
  case anywhere in the client or the existing pairing-code protection.
- `FriendsController` polls `listFriends()` + per-friend
  `getFriendStatus()` every 5 seconds while the Friends screen is
  mounted, the same `Timer.periodic`-under-`Notifier.autoDispose` shape
  already used by `DownloadsController` for the transfer queue.
- `FriendsScreen`: friend list with a green/grey status dot, an inline
  bottom sheet for Musicat Server host/port/public-address setup (shown
  as the whole screen body when unconfigured, reachable afterwards via an
  app-bar icon — deliberately not a `/settings` route), and an "add
  friend" bottom sheet combining this device's own generated pairing code
  with a form to redeem a friend's.
- New top-level nav destination and `/friends` route, alongside the
  existing five, in `app_shell.dart`/`app_router.dart`.

## Consequences
- Real, end-to-end verified: two live `dart run bin/server.dart`
  processes, driven only through the real `FederationClient` class (no
  mocks) via a throwaway script — code generation, cross-redemption in
  both directions, `listFriends()` reflecting the new trust on both
  sides, `getFriendStatus()`, a deliberately wrong code correctly
  rejected (403), and `removeFriend()` actually removing it. Script
  deleted after use.
- `flutter analyze` clean, all 120 app tests still passing.
- Still open, not addressed by this slice: no UI yet for the sharing
  mechanism itself (browse-what's-shared-with-me, share button on a
  track, playlist screens) — this slice is friend management only. NAT
  traversal across a real network boundary also remains unverified (see
  ADR 0021/0024).
