# 0032 — Real cross-NAT hole-punch test: negative result

## Context
ADR 0023/0024 both explicitly flagged the same open item: the UDP
hole-punch had only ever been exercised over loopback/same-LAN, never
across two genuinely different real networks, because no second network
was available. Jorge got hold of one today — his phone on mobile data
(WiFi off), Termux + the Dart SDK, running the exact same
`StunClient`/`UdpPuncher` primitives as the real server, against this
machine's home connection.

Before running anything, reading the actual code
(`federation_routes.dart`, `sharing_routes.dart`, `playlist_routes.dart`)
surfaced a separate, already-documented-but-unresolved fact worth
restating here since it shaped the test's scope: pairing (`POST
/friends`) and every real feature call (sharing, playlist sync) are
plain HTTP over TCP, addressed directly at the peer's `host:port`.
`UdpPuncher` only ever sends a fixed signed liveness blob — nothing
routes real traffic over the punched UDP path (ADR 0023 already says
this). So a full "pair two NAT'd nodes via the app with zero
port-forwarding" test was never going to succeed regardless of the
UDP result: the pairing HTTP call itself needs one side already
TCP-reachable, full stop. Jorge chose to test the narrower, still
genuinely unverified question instead: **does the raw STUN+hole-punch
mechanism work at all across his home NAT and his mobile carrier's
NAT** — bypassing the HTTP pairing flow entirely by manually seeding
each side's `FriendStore` with the other's real `nodeId`/public key
(exchanged out of band, over chat) and driving `UdpPuncher.punch()`
directly.

## What was tested
A throwaway interactive script (`server/tool/manual_verify_cross_nat_punch_temp.dart`,
deleted after use, never committed) on both ends:
1. Loads/creates a real `NodeIdentity`.
2. Runs `StunClient.detectMappingBehavior()` against two independent
   Google STUN endpoints from the same local port.
3. Binds a real `UdpPuncher`, STUN-discovers its own external candidate.
4. Waits (keeping the same socket/mapping alive) for the operator to
   manually enter the peer's `nodeId`/public key/candidate, then seeds
   `FriendStore` with it directly (no HTTP call) and calls
   `puncher.punch()` for 30s, followed by 30s of `isConnected` polling
   via the keepalive path.

Both sides independently reported `NatMappingBehavior.consistent` —
the STUN heuristic for a favorable (cone-type) NAT that ADR 0021
originally used to justify attempting hole-punching at all. Home side:
`91.116.117.4` (Spanish residential ISP). Mobile side: `46.222.93.111`
(a different real public IP, confirming genuinely separate networks
once Jorge actually disabled WiFi — the first attempt was invalidated
by the phone still being on the same home WiFi as this machine, caught
by both candidates showing the identical public IP).

Two attempts were run. The first had poor timing (Jorge entered this
node's data into his prompts, *then* sent his own fresh info back —
meaning his 30s punch window may have been mostly or fully elapsed
before this side even started sending). The second attempt fixed that:
both sides pre-shared their fresh info while still idling at the input
prompt (before either had started sending anything), then entered each
other's data within seconds of one another, confirmed by both sides
independently seeing "Punching toward..." close together.

## Result
**Total, symmetric failure on both attempts** — including the
well-synchronized second one. Neither side ever received a single
valid signed packet from the other, across the full 30s burst
(interval 300ms, ~100 packets sent) plus 30s of subsequent keepalive
polling (`isConnected=false`/`lastSeen=null` throughout, 6/6 checks, on
this side; Jorge's side reported the equivalent "no reply heard").

## Analysis
Both NATs independently passed the exact heuristic ADR 0021 used to
decide hole-punching was worth attempting (`NatMappingBehavior.consistent`,
i.e. STUN queries to two different servers from the same local port
got the same external mapping) — yet the actual punch never got a
single packet through in either direction, with confirmed good timing
on the second attempt. This means **the "consistent mapping" STUN
heuristic is necessary but not sufficient evidence that hole-punching
will work**. Plausible causes, none confirmed by this test alone:
- The two-Google-STUN-server check isn't diverse enough to catch every
  form of endpoint-dependent behavior a mobile carrier's NAT/CGNAT might
  actually exhibit against a real, unrelated third peer.
- A carrier-side stateful firewall or DPI middlebox dropping UDP that
  doesn't match a recognized protocol signature, independent of NAT
  mapping behavior entirely — increasingly common on mobile networks
  specifically, and something no client-side STUN check can detect.
- Simple policy-level blocking of P2P-shaped traffic patterns by the
  carrier.

Distinguishing these would need further diagnostics (e.g. a controlled
third-party reachability/echo test, or repeating this against a
different mobile carrier or a different home connection) — not done
here, and not clearly worth doing before deciding how to proceed.

## Decision
No code changes from this ADR — it's a real-world result, not a bug.
**ADR 0021's original fallback requirement stands, confirmed rather
than superseded**: hole-punching cannot be relied upon even when both
sides look individually favorable by the one heuristic available
before actually trying. For V1, at least one side of a friendship
still needs to be independently reachable (port-forward, DDNS, or a
VPN mesh) for cross-network pairing/sharing to work at all — exactly
what ADR 0021 said before any of the STUN/hole-punch work was built,
now empirically reinforced rather than resolved by it.

## Consequences
- The plan's Fase 4 "Hecho cuando" (two instances across genuinely
  different networks pairing and sharing) is **still not achieved**
  for the fully self-contained, zero-configuration case — it needs
  either the ADR 0021 fallback (one side reachable some other way) or
  future work Musicat hasn't built: routing real traffic over a
  successfully punched UDP path (moot here, since the punch itself
  failed for this network pair) or a self-hosted relay/TURN-style
  fallback for when hole-punching doesn't work, which is a materially
  bigger feature than anything built so far in Fase 4's NAT work.
- The STUN/hole-punch/keepalive code itself (ADR 0022-0024) isn't
  wasted: it still helps the subset of friend-pairs where it *does*
  work (e.g. two favorable home NATs, which is genuinely common), and
  the negative result here is itself valuable, real information about
  which networks it *doesn't* help — worth remembering before treating
  "NAT traversal: consistent, listening for punches" in a startup log
  as any kind of guarantee.
- Practical scope question for Jorge going forward, not resolved here:
  whether to invest in a relay fallback (bigger, but gets closer to the
  original "no port-forward, no separate tool" ambition), accept the
  ADR 0021 fallback permanently and document it clearly in user-facing
  setup instructions, or leave this as a known limitation and move on
  to other Fase 4 work.
