# 0023 — UDP hole-punch integrated into pairing

## Context
ADR 0022 gave Musicat Server its own STUN client — enough to learn a
node's real external `ip:port`, but that alone connects nothing. Two
nodes still need to (a) exchange those discovered addresses and (b)
actually attempt the hole-punch, all without requiring the user to run
separate software (ADR 0021/0022's framing, per Jorge's explicit call).
The pairing-code exchange (ADR 0020) is the one moment a channel between
two nodes is already open and mutually authenticated-enough (a fresh
one-time code was just proven) — using that same moment to also carry
STUN candidates means no new signaling channel has to be invented.

## Decision
- **`UdpPuncher`** (`server/lib/src/nat/udp_puncher.dart`) binds one UDP
  socket for the server's lifetime (`MUSICAT_UDP_PORT`, default random) and:
  - `refreshCandidate()` — STUN-discovers this node's own external mapping
    on that socket, caching it (`cachedCandidate`, a synchronous getter —
    request handlers read the cache rather than each triggering a live
    STUN round-trip).
  - `punch(host, port, duration, interval)` — sends a signed UDP packet
    toward the target repeatedly for a few seconds (a burst, not one
    perfectly-timed packet — neither side can know the other's exact
    timing) while listening for a validly-signed incoming packet from any
    known friend; resolves to that friend's `nodeId` on success.
  - Punch packets reuse `RequestSigner`/`RequestVerifier` verbatim (ADR
    0019), with a fixed pseudo method/path (`UDP-PUNCH` /
    `/nat/punch`) standing in for what an HTTP request's method/path would
    be. Accepting a signed punch packet is exactly as trustworthy as
    accepting a signed HTTP request from the same friend — no separate,
    weaker check invented for UDP.
- **`Friend` gains an optional `udpCandidate`** (`host:port`), and `POST
  /friends` now accepts one from the caller and returns this node's own
  current one in the response. When a candidate is provided, the server
  immediately fires an unawaited `punch()` toward it in the background —
  pairing itself is the trigger, nothing else has to ask for it.
- Both `/pairing-codes` and `/friends` still sit outside
  `RequestVerifier` (ADR 0020's reasoning still applies), but the punch
  packets they trigger absolutely do not — an attacker sending punch
  packets without a friend relationship gets silently ignored, same as
  ADR 0019 always intended for anything that matters.

## Consequences
- Unit-tested: `UdpPuncher` against two real local UDP sockets (no fakes
  needed — this is the same "just use a real instance, it's fast and
  deterministic" pattern as `FriendStore`/`RequestVerifier`'s own tests) —
  mutual friends punch through, a non-friend's packets are correctly
  ignored, and calling `punch()` before `bind()` throws. The route-level
  tests cover `udpCandidate` validation/storage without needing a live
  STUN round-trip (the route only reads a cache, never triggers one).
- **Verified for real, fully automatically, across two real running
  server processes**: paired them in both directions over real HTTP,
  each providing its own *real* STUN-discovered candidate (via loopback,
  to sidestep NAT-hairpinning uncertainty — see below) — with no manual
  `punch()` call from the verification script, pairing alone triggered
  a real background punch on both sides, and both servers' own logs
  (via a temporary debug print, removed before committing) confirmed
  they received and verified the other's signed packet within seconds.
- **Still not verified**: an actual punch across a real NAT boundary
  (hairpinning through one router's own public IP, or genuinely across
  two different networks) — everything above ran over loopback on one
  machine. Jorge doesn't currently have a second real network available
  that doesn't involve either exposing a port or installing a separate
  tool (both explicitly out of scope per ADR 0021/his own call), so this
  remains open until one becomes available.
- No keepalive yet — a punched hole isn't maintained once established.
  If either side's NAT mapping expires or its network changes, the hole
  closes and re-punching requires going through pairing again (or a
  future "reconnect" flow that isn't built). This is the next gap, not
  closed here.
- Nothing routes real federation traffic (search results, playlists, ...)
  over the punched UDP channel yet — this slice only proves the channel
  itself opens and can carry a trusted signed message. What normal
  traffic looks like once opened (stay on UDP with a custom protocol, or
  attempt to also open a TCP path for the existing HTTP API) is an open
  question for a later slice.
