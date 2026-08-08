# core/network/soulseek

The `SoulseekClient` interface and its implementations — see
[ADR 0004](../../../../../docs/adr/0004-networking-abstraction.md).

- Phase 2: `slskd/` — talks to a self-hosted `slskd` instance over REST.
- Phase 3: `musicat_server/` — talks to the self-hosted Musicat Server,
  which itself wraps `slskd`.
- Future phase: a native Dart Soulseek client implementation.
