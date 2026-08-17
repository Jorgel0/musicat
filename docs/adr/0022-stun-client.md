# 0022 — STUN client (Fase 4, NAT traversal step 1)

## Context
ADR 0021 recommended relying on an already-reachable address (port-forward/
DDNS/VPN) for Fase 4 V1, since full NAT traversal can't be guaranteed for
every network combination. Jorge pushed back on that framing: Musicat
should be as self-contained as possible — a user shouldn't have to install
separate third-party software (like Tailscale) just to use a built-in
feature. That's a reasonable bar, and it doesn't actually conflict with
ADR 0021's underlying technical finding (some NAT combinations genuinely
can't traverse without *some* relay) — it just means Musicat should
attempt real NAT traversal itself, automatically, for the networks where
it's actually possible (which, per ADR 0021's own real test, includes
Jorge's own network), rather than defaulting straight to "go set something
else up." This is the first concrete step: a STUN client living inside
Musicat Server, not a separate tool.

## Decision
- **`StunClient`** (`server/lib/src/nat/stun_client.dart`) implements
  RFC 5389 Binding Requests/Responses over raw UDP (`dart:io`'s
  `RawDatagramSocket`) — no external package, no separate process.
  `discover()` asks one public STUN server what external `ip:port` it
  observed for a given local port; `detectMappingBehavior()` asks several
  independent servers from the *same* local port and compares — agreement
  signals a cone NAT (favorable for hole-punching), disagreement signals
  symmetric NAT (see ADR 0021).
- The wire encoding/decoding (`buildStunBindingRequest`/
  `parseStunBindingResponse`) is split out as pure, standalone functions
  so it's unit-testable without any real network I/O — mirroring the
  project's established pattern of testing protocol logic against
  hand-built bytes (or fake HTTP) rather than a live dependency, and
  reserving the real dependency for manual, real-network verification.
- Public STUN servers (Google's, Cloudflare's) are used as the discovery
  helper. This isn't the same category of dependency as installing
  Tailscale: STUN is a lightweight, stateless, one-packet-round-trip
  protocol with no account, no data relay, and no ongoing relationship —
  closer to how NTP or DNS are incidental infrastructure any networked
  app relies on than to installing a separate application.

## Consequences
- Unit-tested: request encoding, response parsing (XOR-MAPPED-ADDRESS and
  the older MAPPED-ADDRESS fallback), and rejection of a mismatched
  transaction id / wrong message type / truncated data — all against
  hand-built STUN messages, no network needed, so this runs safely in CI.
- **Verified for real against Jorge's actual network**: the real
  `StunClient`, not just the unit tests, reproduced ADR 0021's earlier
  Python-prototype finding exactly — all three independent public STUN
  servers reported the identical external mapping from the same local
  port, confirming `NatMappingBehavior.consistent` (cone NAT) end to end
  through the real Dart implementation.
- This is only step 1. `StunClient` can tell a node its own reachable
  address and roughly how favorable its NAT is — it does **not** yet
  exchange that address with a friend, attempt a UDP hole-punch, or
  maintain one with keepalives. Per the plan agreed with Jorge, the next
  slice integrates this into the pairing flow (exchange STUN-discovered
  candidates at pairing time, since that's the one moment a signaling
  channel is already open) and adds the actual hole-punch handshake.
- The fundamental limit from ADR 0021 still applies and isn't solved by
  this slice: two nodes that are *both* behind symmetric NAT, with no
  prior established channel, genuinely cannot connect without a relay —
  no amount of STUN client code changes that. This slice narrows how
  often that limit is actually hit (automatic, no-install traversal for
  the common favorable case) rather than eliminating it.
