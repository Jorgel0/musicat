# 0004 — SoulseekClient as a swappable interface

## Context
Soulseek integration is planned to change backend strategy at least twice:
a self-hosted `slskd` instance (Phase 2), then a self-hosted Musicat Server
that wraps `slskd` (Phase 3), then possibly a native Dart Soulseek client
per device (future phase). The friend-sharing feature (Phase 4) also needs
a backend-to-backend interface that shouldn't leak into feature code.

## Decision
Define `SoulseekClient` as an interface in
`app/lib/core/network/soulseek/soulseek_client.dart` from Phase 1 onward
(even before it has a real implementation). Each backend strategy is a
separate implementation behind that interface. Similarly, reserve
`core/network/social/` for the Phase 4 federation interface.

## Consequences
- Search/downloads/library-import feature code depends only on the
  interface, never on `slskd` or HTTP specifics directly.
- Tests mock `SoulseekClient`, so contributors without a Soulseek account or
  a running `slskd` instance can still work on and test search/download UI
  and logic.
- Switching backend strategy in a later phase is additive (new
  implementation + a settings toggle), not a rewrite.
