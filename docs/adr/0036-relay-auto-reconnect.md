# 0036 — Automatic relay reconnect, mobile-data-conscious

## Context
ADR 0033 flagged this explicitly as a gap: `RelayClient.connect()` is a
single attempt — if a tunnel that was working drops (relay restart,
network blip, a phone briefly losing signal), the node's relay fallback
is silently gone for good until the whole process is restarted. This
stopped being a hypothetical the moment ADR 0035's relay went into real
use between two real nodes across different networks, one of them a
phone.

Built via `/dev-team` (backend-dev round) at Jorge's direction, going
forward, for implementation work in this repo.

## Decision
- **A connection that [`connect()`] established successfully and later
  drops now reconnects automatically in the background**, to the same
  URL, with no external call required. A connection that never
  succeeded in the first place is *not* retried — `connect()`'s
  synchronous `false` return still means exactly what it did before,
  since `bin/server.dart` relies on it unchanged to decide whether to
  advertise this node's `relayUrl` to friends at startup.
- **Mobile-data constraint, from Jorge directly**: this process can run
  on a phone on a real, possibly limited mobile data plan (see ADR
  0035). Reconnecting must not hammer the network:
  - Before every retry tick, a cheap local check
    (`NetworkInterface.list(includeLoopback: false)` — an OS query, zero
    network I/O) skips the actual connection attempt entirely if the
    device has no active network interface at all (airplane mode, data
    toggled off). That tick doesn't count as a failure — the backoff
    doesn't escalate for a tick that never actually tried anything.
  - When an interface is present and an attempt is made but fails, the
    backoff doubles, starting at 5s and capped at 5 minutes — deliberately
    more conservative than a typical desktop-service reconnect loop, so
    a long outage settles into infrequent, cheap retries rather than
    continuous attempts.
  - A successful (re)connect resets the backoff to the 5s starting
    point, since most real drops are short blips, not long outages.
- `close()` cancels any pending scheduled reconnect timer, and a
  reconnect attempt that happens to be in flight when `close()` runs is
  torn back down rather than left open — no resurrecting a tunnel after
  an intentional shutdown.
- **New `RelayHub.disconnect(nodeId)`**: forcibly closes one node's
  tunnel from the hub side. Added because it turned out to be the only
  realistic way to test a mid-session drop — once a connection is
  upgraded to a WebSocket, `shelf_web_socket`'s hijack detaches it from
  the underlying `HttpServer` entirely, so even `HttpServer.close(force:
  true)` leaves already-open tunnels running untouched. Doubles as a
  legitimate small operational primitive (kicking a node) independent of
  the tests that motivated it.

## Consequences
- `NetworkInterface.list()` is a real signal but an imperfect one — an
  interface can be up with no actual route out (e.g. Wi-Fi joined to an
  AP with no upstream). It's deliberately scoped as a cheap way to skip
  the clear-cut "no network at all" case, not a substitute for a real
  connectivity check.
- `dart analyze`/`dart test` clean; server test count 147 → 151. New
  tests in `relay_client_test.dart` (all real `RelayHub` + real
  `shelf_io.serve` + real `RelayClient`, no mocks, matching this
  codebase's established convention for this kind of code): a dropped
  tunnel reconnects on its own with no external call and correctly
  serves a request afterward; `close()` genuinely cancels a pending
  scheduled reconnect rather than merely coinciding with unreachability;
  and the retry loop stays alive and never falsely reports itself
  connected through several backoff cycles while the relay is down for
  good. Verified directly against the actual diff and by re-running
  `dart analyze`/`dart test` myself, not just trusting the subagent's
  report.
- Not attempted here, and not needed for it: actually simulating "zero
  network interfaces" in a test — this dev environment (and presumably
  CI) always has at least one real non-loopback interface, and tearing
  one down would affect the host, not just the test process. That branch
  is covered by code review and by the adjacent "interface present but
  relay unreachable" test, which exercises the same surrounding
  retry/backoff machinery via the other side of the same `if`.
- Still open, unrelated to this ADR's scope: no UI visibility into
  whether a friend has a relay on file or whether a given request
  actually used one; no invite-link/QR for sharing a relay address or a
  joint-playlist id.
