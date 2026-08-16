# 0017 — App-side Musicat Server client and backend selection

## Context
With Musicat Server wrapping slskd (ADR 0016), the app needs its own
`SoulseekClient` implementation that talks to the server instead of slskd
directly, plus a way for the user to pick which backend to use — this is
the last piece of Fase 3's "Hecho cuando" bar (search/download working
exactly as in Fase 2, but optionally routed through Musicat Server).

## Decision
- **`MusicatServerSoulseekClient`**
  (`app/lib/core/network/soulseek/musicat_server/`) implements
  `SoulseekClient` against `/api/v1/soulseek/*`. Because the server already
  did slskd's quirk-handling (ADR 0016), this client is much thinner than
  `SlskdSoulseekClient`: no tree-flattening, no transfer-state-flag
  parsing, and — notably — `startSearch` is a plain awaited
  request/response call, not a fire-and-forget POST + client-generated
  UUID. Musicat Server's own `startSearch` already returns as soon as the
  search is registered (verified in ADR 0016), so the app doesn't need to
  know or care that slskd's own search endpoint blocks.
- **`SoulseekConfig` gains a `backendType`** (`slskd` | `musicatServer`).
  `apiKey` is only meaningful for `slskd` — a Musicat Server instance holds
  its own slskd API key server-side, so the app never needs one for that
  path. `isConfigured` reflects this (host alone is enough for
  `musicatServer`).
- **`buildSoulseekClient(SoulseekConfig)`**
  (`soulseek_client_factory.dart`) is the single place that maps a config
  to a concrete client, used by both `soulseekClientProvider` and the
  Settings screen's "Test connection" button — so they can't disagree
  about which backend a saved config actually points at.
- **Settings UI**: a `SegmentedButton` toggle between "Direct slskd" and
  "Musicat Server". The API key field only shows for the direct-slskd
  option; switching backends nudges the port field to the new backend's
  default (5030 / 8080) *only* if it was still at the previous backend's
  default, so an already-customized port is left alone.
- **Not retiring direct slskd.** Both paths stay fully supported side by
  side — Musicat Server isn't required to use Soulseek search/downloads at
  all, and a single-device desktop setup with slskd running locally has no
  real need for the extra hop.

## Consequences
- Unit-tested against `dio`'s fake adapter, same pattern as
  `SlskdSoulseekClient` (`test/musicat_server_soulseek_client_test.dart`),
  plus updated `SoulseekConfigController`/`soulseekClientProvider` tests
  covering both backend types and persistence of `backendType`.
- **Verified against the real, running stack**: with a live local Musicat
  Server (pointed at the real CT slskd instance with a deliberately wrong
  API key, per [[feedback_no_credential_retrieval]]), a throwaway script
  exercising the actual `MusicatServerSoulseekClient` class confirmed the
  real 401 propagates as a `SoulseekClientException` through the app's own
  code path, and `getDownloadsDirectory` degrades to `null` rather than
  throwing — the same real-network confirmation ADR 0016 did server-side,
  now one hop further out through the app's client too.
- This closes Fase 3's core loop end-to-end (app → Musicat Server → slskd)
  for search and downloads. Still open, deliberately left for later: the
  app never surfaced a *successful* authenticated search/download through
  this path (needs real slskd credentials to verify), and Docker Compose
  for self-hosting the whole stack — the last items on Fase 3's plan.
