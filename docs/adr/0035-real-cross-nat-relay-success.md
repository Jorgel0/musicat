# 0035 — Real cross-NAT verification: the relay works

## Context
ADR 0032 found hole-punching fails for a real home-network + mobile-data
pair. ADR 0033/0034 built and wired a self-hosted relay fallback,
verified thoroughly but only on loopback/one machine. This closes the
loop: a real relay, deployed on Jorge's own infrastructure, reachable
from a genuinely different network (his phone on mobile data), carrying
a full pairing + share + download flow end to end.

## Getting there: three real infrastructure dead ends before it worked
Deploying *anything* Jorge's phone could reach turned out to be most of
the actual work, none of it a Musicat code problem:

1. **Port-forwarding on Jorge's own home router** — set up correctly
   (ZTE F6640, TCP 8090 → his existing Proxmox CT at `192.168.1.140`,
   already running `musicat-relay` as a systemd service, installed via
   the same apt-repo Dart install used elsewhere in this project) — but
   unreachable from outside. Cause: the router's own WAN IP
   (`100.117.160.145`) was itself inside `100.64.0.0/10`, the reserved
   CGNAT range (RFC 6598) — Jorge's ISP was NATting his whole connection
   before it ever reached his router, so no port-forward on his side
   could ever work, correctly configured or not.
2. **IPv6 as a free way around it** — checked the router's WAN status:
   IPv6 "Connected" at the link layer, but `GUA: ::` (no address
   assigned) despite "Request PD" already enabled. The ISP simply
   doesn't delegate a prefix on this line — a dead end, not a
   configuration problem.
3. **Oracle Cloud Always Free** as a fallback with a real public IP by
   default — got as far as a correctly-configured VCN with a public
   subnet and internet gateway, but instance creation failed with
   `Out of capacity` for both Always-Free-eligible shapes
   (`VM.Standard.E2.1.Micro` and the Ampere `VM.Standard.A1.Flex`) in
   Jorge's only availability domain — a well-known, shared-capacity
   limitation of that tier, not fixable from the console.
4. **Resolved for real**: Jorge contacted his ISP (R) and asked
   specifically for a public IPv4 (not IPv6, not "faster internet" —
   the precise ask mattered for getting routed to someone who could
   action it), and got one, free, same day. Confirmed by matching the
   router's new WAN IP (`178.60.174.231`) against `curl ifconfig.me`
   from a machine on that LAN — identical, meaning the router now holds
   a real, directly-routable address. The original port-forward rule to
   the CT worked immediately once this was true — first proven by a
   real `curl` from Jorge's phone on mobile data getting the relay's own
   `502` (its correct answer for an unknown node), then by the full test
   below.

## The actual test
Two real `dart run bin/server.dart` processes, `MUSICAT_RELAY_URL`
pointing both at the same relay (`178.60.174.231:8090`, the CT from ADR
0033) — one on this machine (home LAN), one on Jorge's phone in Termux,
genuinely on mobile data (confirmed by a different external IP than the
home connection's). Pairing was addressed at each side purely via the
relay (`<relay>/<nodeId>/...`, the only way to reach either side without
assuming direct reachability); after that, both `SharingClient` calls
(list shared tracks, download a file) went through the *unmodified*
production client — no relay-specific addressing in the app code at all,
relying entirely on ADR 0034's automatic direct-then-relay fallback
inside the server itself.

**Result: fully successful.** Pairing completed in both directions
through the relay; A's shared track was visible to B; the file
downloaded to B matched A's original bytes exactly.

## A real bug found during this test
The first attempt failed with a `502`/connection-refused once B tried
to actually fetch what A shared. Cause: this machine's own
`MUSICAT_RELAY_URL` had been set to the CT's **LAN address**
(`ws://192.168.1.140:8090/connect`) rather than its public one, since
this machine happens to be on the same LAN as the relay and that
avoids a hairpin-NAT round-trip for its *own* connection. But
`Friend.relayUrl` is not just "how I reach the relay" — it's what gets
*advertised to friends* as the fallback address they should use, and a
friend on a different network entirely (Jorge's phone) has no route to
a `192.168.x.x` address at all. Fixed by using the relay's public
address uniformly regardless of which node happens to be topologically
close to it — the correct general rule: **always advertise the relay's
one canonical, externally-valid address, never a locally-convenient
one**, even from a node that could technically reach it more directly.
Not a code bug (nothing to fix in `RelayClient`/`Friend` — this is
purely an operational/configuration concern), but worth remembering
for `docs/self-hosting.md` whenever that gets written.

## Consequences
- Phase 4's plan-level "Hecho cuando" (two instances across genuinely
  different networks pairing and sharing) is now **achieved for real**,
  via the relay path — not via hole-punching, which ADR 0032 showed
  doesn't work for this exact network pair, but the plan's bar didn't
  specify *how*, only that it works.
- The relay CT (`192.168.1.140:8090`, `musicat-relay` systemd service)
  and its port-forward stay in place as a real, working, deployed relay
  — Jorge could keep using it, or point a future relay-hosting doc at
  this exact setup as a worked example.
- Still open, unrelated to this ADR's scope: no invite-link/QR for
  sharing a relay's address or a joint-playlist id (manual copy-paste
  only throughout Phase 4); no reconnect logic if the relay drops after
  a node's startup; the "advertise the canonical address, not a local
  one" lesson above isn't enforced by any code — a future multi-relay or
  multi-node-per-LAN setup could hit the same mistake again since
  nothing currently warns about it.
