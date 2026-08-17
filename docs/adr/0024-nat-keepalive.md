# 0024 — NAT hole-punch keepalive

## Context
ADR 0023 could open a UDP hole between two friends but never maintained
it — a NAT mapping with no traffic eventually expires (typically well
under a minute for UDP on most consumer routers), so the very connection
just proven working would quietly go stale. This closes that gap.

## Decision
- **`UdpPuncher` gains a persistent listener** (moved out of `punch()`,
  set up once in `bind()`) that verifies every incoming packet and
  records `_lastSeen[nodeId]` for *any* known friend, not just during an
  active `punch()` call — `punch()` now just awaits the next event on a
  shared broadcast stream fed by that listener.
- **`lastSeen(nodeId)`/`isConnected(nodeId, {within})`** — the practical
  "is this friend's hole still open" check, based on how recently a
  signed packet arrived (default staleness window: 45s).
- **`startKeepalive`/`stopKeepalive`** — a per-friend `Timer.periodic`
  that keeps sending a signed packet toward a friend's candidate (default
  every 20s, comfortably under the 45s staleness window and typical NAT
  UDP timeouts) until stopped. Revoking a friend (`DELETE
  /friends/<nodeId>`) now also stops maintaining it. `GET
  /friends/<nodeId>/status` exposes `connected`/`lastSeen` for observability.
- **`punchAndMaintain`** ties `punch()` and `startKeepalive` together —
  what `POST /friends`' background trigger now calls instead of bare
  `punch()`.
- All packets (initial punch burst and ongoing keepalives) use the exact
  same signed-payload shape — there was never a reason for the wire
  protocol to distinguish "proving I'm nodeId X for the first time" from
  "proving it again a bit later."

## Consequences
- Unit-tested (`UdpPuncher`, real local UDP sockets, same "no fakes
  needed" pattern as ADR 0023): `isConnected`/`lastSeen` before and after
  a punch, a keepalive sustaining `isConnected` well past what a one-shot
  punch's own window would, `stopKeepalive` letting it go stale again, and
  the route layer's `stopKeepalive`-on-revoke and `/status` shape.
- **A real bug, caught only by extended real-network testing, not by any
  unit test**: `punchAndMaintain`'s first version only called
  `startKeepalive` if the *initial* `punch()` call itself heard a reply
  within its 5-second window. Running two real server processes and
  polling `/status` on both sides over ~40 seconds showed a genuinely
  asymmetric result — one side reported connected, the other never did,
  and which side "won" flipped between runs. The actual cause: a side's
  outbound packets could reach the peer fine while that same side's own
  initial receive attempt simply timed out first (ordinary timing
  variance, not packet loss) — and treating that as failure meant it gave
  up sending anything further, even though it was already working in one
  direction and likely would have gone both ways moments later. Fixed by
  making `punchAndMaintain` start the keepalive unconditionally: sending
  is what keeps *your own* NAT mapping open for the peer, which doesn't
  depend on whether you've personally confirmed the reverse direction
  yet. Re-verified over the same ~40-second real two-process test after
  the fix: both sides showed `connected: true` throughout, with `lastSeen`
  refreshing roughly every 20 seconds on each side as expected.
- Still not covering: keepalive doesn't survive a server restart for
  *existing* friends — it's only ever armed as a side effect of the
  `POST /friends` pairing flow, so a friend from before a restart has no
  active keepalive until the next fresh pairing. A "reconnect all known
  friends on startup" pass is a reasonable follow-up, not built here.
- Still not covering, same as ADR 0023: verification across a real NAT
  boundary (only loopback so far), and routing actual federation traffic
  (search, playlists, ...) over the maintained channel rather than a bare
  signed liveness packet.
