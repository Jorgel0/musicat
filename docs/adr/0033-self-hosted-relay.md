# 0033 — Self-hosted relay fallback for when hole-punching fails

## Context
ADR 0032 found, with a real cross-network test, that NAT hole-punching
(ADR 0021-0024) — Musicat's own answer to "no separate tool, no exposed
port" — simply doesn't work for at least one real network pair (home ISP
+ mobile carrier), despite both individually looking favorable by the
only heuristic available before actually trying. Jorge's direction:
build a self-hosted relay rather than fall back to recommending a
third-party VPN mesh (Tailscale) — staying closer to the original "no
separate tool" ambition, at the cost of building more of it ourselves.

A relay only helps if *some* host in the picture has genuine public
reachability — that's unavoidable; the point is that host doesn't have
to be either friend's own device, and it's Musicat's own code (AGPL,
self-hostable, no third-party account), not a dependency on someone
else's service.

## Decision
- **`RelayHub`** (`server/lib/src/relay/`, new standalone entry point
  `bin/relay.dart`) — deployed separately, on a host with real public
  reachability. A Musicat Server connects to it with a single
  *outbound* WebSocket (which any NAT permits, unlike the inbound
  reachability hole-punching tries to solve), authenticates, and the hub
  forwards ordinary HTTP requests addressed at `<relay>/<nodeId>/<path>`
  through that tunnel, returning whatever comes back.
- **Self-certifying authentication, no pre-existing trust needed**: a
  nodeId is already the SHA-256 fingerprint of the node's own Ed25519
  public key (`NodeIdentity`) — the hub checks a connecting client's
  claimed nodeId against a fingerprint of the public key it provides,
  then challenges it to sign a fresh nonce, proving it holds the matching
  private key. This needs no friend list on the hub's side; it only
  proves "this connection really controls nodeId X", never anything
  about who X is allowed to talk to.
- **The hub is a dumb pipe, deliberately**: it never inspects, trusts, or
  authorizes the *content* being relayed — that's still entirely the
  *receiving* Musicat Server's own job (`RequestVerifier`, object-level
  checks), applied identically whether a request arrived directly or
  through the relay, since `RelayClient` (the piece that runs inside a
  normal Musicat Server) hands every tunneled request to the exact same
  `Handler` the server already uses for direct HTTP.
- **Existing client code needs zero changes to use a relay**: since the
  relay's forwarding route is `<relay>/<nodeId>/<path>`, pointing a
  client's `baseUrl` at `<relay>/<targetNodeId>` instead of the peer's
  direct address is enough — every existing relative path (pairing,
  sharing, playlist sync) composes correctly with no code changes, as
  verified for real below.
- **Opt-in, additive**: `bin/server.dart` only attempts to connect to a
  relay if `MUSICAT_RELAY_URL` is set; a failed or absent relay
  connection is logged, never fatal — direct reachability and NAT
  hole-punching keep working exactly as before for nodes that don't need
  a relay at all.

## Consequences
- Unit-tested with real WebSocket connections end to end (no fakes) —
  `relay_hub_test.dart` covers authentication (real identity succeeds; a
  claimed nodeId not matching the provided public key is rejected; an
  invalid signature over the challenge is rejected), forwarding to an
  unconnected node (502, not a hang), a real request/reply round trip
  through a manually-driven tunnel, a timeout when the tunnel never
  answers (504), and tunnel cleanup on disconnect.
  `relay_client_test.dart` covers the full hub+client integration: a
  request forwarded through the relay reaches a real local `Handler`
  exactly like a direct one would, the local handler's own
  authorization still applies (never bypassed by the relay), POST
  bodies survive intact, `connect()` fails cleanly (not an exception)
  against an unreachable relay, and `close()` actually disconnects.
- **Real, three-real-process end-to-end verification** (throwaway
  scripts, deleted after use): a real `bin/relay.dart`, and two real
  `bin/server.dart` instances each configured with `MUSICAT_RELAY_URL`
  pointing at it. Addressing each other *exclusively* through the relay
  (never their own direct `localhost` ports) —
  1. **Pairing itself** (`POST /friends`, the call ADR 0032 found
     absolutely requires direct reachability) succeeded in both
     directions purely through the relay, using the existing
     `FederationClient` unchanged.
  2. A real signed federation-facing request (`GET
     /api/v1/sharing/shared-tracks`, using each node's real, persisted
     identity) survived the relay's JSON+base64 tunnel intact — the
     receiving node's real `RequestVerifier` accepted it.
  3. A real file download (`GET .../shared-tracks/<id>/file`) round-tripped
     byte-for-byte through the relay — a materially different code path
     (raw bytes, not JSON) from the two checks above.
  4. A forged, unsigned "stranger" request through the same relay path
     was still correctly rejected (401) — confirming the relay didn't
     accidentally create an authorization bypass.
- **A real bug caught and fixed during this verification, before it ever
  reached a test**: `IOWebSocketChannel.connect(uri)` — the concise,
  natural way to open a client connection — wraps a not-yet-connected
  socket in a lazily-resolved `Future` internally; when that connection
  fails, the error surfaces *twice*: once as a catchable stream error
  (which a `try`/`catch` around `connect()` handled fine) and once as a
  genuinely separate, unhandled async error from the channel's internal
  sink-side subscription to that same future, escaping any try/catch
  around the calling code entirely and crashing the whole process. Found
  via a minimal repro script before it was ever wired into `RelayClient`
  for real. Fixed by connecting via the lower-level `WebSocket.connect()`
  first (a single, fully awaited, genuinely catchable `Future`) and only
  wrapping the result in a channel afterward — confirmed the double-error
  no longer occurs with the same repro.
- `dart analyze`/`dart test` clean; server test count 127 → 139 (12 new
  relay tests, all exercising real network I/O per this project's
  established convention for this kind of code).
- Explicitly **not** done in this slice, left for a follow-up: no
  "try direct, fall back to relay" logic in the actual production call
  sites (`sharing_routes.dart`'s friend proxy, `playlist_routes.dart`'s
  sync, the app's `addFriend`) — those all still address a friend at
  their stored direct `Friend.address` only. No way yet for pairing to
  also exchange "here's a relay I'm registered with" alongside (or
  instead of) a direct address. No reconnect/retry logic if a relay
  connection drops — `RelayClient.connect()` is a single attempt. No
  real deployment yet (Jorge chose to verify the mechanism on loopback
  first and decide on hosting — a spare VPS, a Raspberry Pi with a
  public IP, etc. — separately) — so the actual cross-NAT scenario ADR
  0032 found broken hasn't been re-tried with a relay in the loop yet,
  only proven correct on one machine.
