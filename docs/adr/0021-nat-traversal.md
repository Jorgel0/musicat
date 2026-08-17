# 0021 — NAT traversal decision (Fase 4 spike)

## Context
The plan explicitly calls out NAT traversal as something to resolve
deliberately in Fase 4, not assume away: two friends' Musicat Server
instances will typically each sit behind a home router's NAT, and nothing
built so far (ADR 0019/0020) helps either one find or reach the other from
outside its own LAN. This is a disposable investigation spike, not a
feature slice — the goal is a decision, not necessarily new code.

## Investigation
Two real, empirical checks against Jorge's actual home network (not
assumptions):

1. **UPnP (automatic port mapping)**: a real SSDP discovery
   (`M-SEARCH`, both the specific `InternetGatewayDevice` search target and
   a broad `ssdp:all`) over UDP multicast on the LAN got **zero responses**
   of any kind. Whether that's UPnP disabled or unsupported on this
   specific router, the practical conclusion is the same: UPnP can't be
   assumed to be available, exactly the plan's own warning against
   assuming NAT traversal "just works."
2. **NAT type (STUN)**: a real STUN binding request, from the *same* local
   UDP port, sent to three independent public STUN servers (Google x2,
   Cloudflare), all returned the **identical** external `ip:port` mapping
   (`91.116.117.4:35521`). Getting the same mapping regardless of which
   remote server is asked is the signature of a **cone NAT** — the
   favorable case for UDP hole-punching. A **symmetric NAT** (common on
   CGNAT/mobile networks) would have returned a *different* external port
   per server, making hole-punching without a relay essentially impossible.

So: this network specifically could support STUN-based hole-punching, but
UPnP isn't available on it, and — critically — there's no way to guarantee
either result for an arbitrary friend's network. Some real-world networks
are symmetric-NATted (mobile carriers, some ISPs' CGNAT) and hole-punching
simply won't work there no matter what Musicat implements.

## Decision
**V1 requires at least one side of a friendship to be independently
reachable**, by whatever means the user already prefers — this needs *no
code change*, since `Friend.address` (ADR 0019) is already a plain
`host:port` string:
- A manual port-forward on the router (works today, zero new code).
- Dynamic DNS, if the public IP isn't static.
- An overlay VPN mesh (e.g. Tailscale, ZeroTier, plain WireGuard) —
  **the recommended path for most users**: these already solve NAT
  traversal properly (including symmetric NAT, via their own relay
  fallback) far better than anything reasonable to build for this project,
  and hand every device a stable address that works as `Friend.address`
  with zero Musicat-side changes.

Building actual STUN-based hole-punching into Musicat Server is
explicitly **not** done in this slice. It only helps the subset of users
on favorable (cone) NATs, doesn't cover symmetric-NAT users at all (they'd
still need the fallback above), and is a meaningfully large chunk of
networking code (STUN client, UDP hole-punch coordination, retry/timeout
handling) for a benefit already covered by recommending an existing,
mature tool.

## Consequences
- No server-side code changes from this slice — the decision is
  documentation/guidance, not implementation. `docs/self-hosting.md`
  should eventually gain a short section pointing users at Tailscale/
  port-forwarding for reaching a friend's node (not added yet — this ADR
  records the decision; wiring it into user-facing docs and the eventual
  pairing UX is a follow-up).
- This means Fase 4's "Hecho cuando" bar ("dos instancias... entre dos
  redes distintas") is achievable *today* with zero new server code, as
  long as at least one instance is reachable by one of the means above —
  worth actually testing for real (e.g. Jorge's CT with a port-forward, or
  a Tailscale link to another real network) before Fase 4 is called done,
  since everything verified so far (ADR 0019/0020) was still on the same
  LAN.
- STUN-based automatic hole-punching remains a possible future
  enhancement (quality-of-life for the common cone-NAT case) layered on
  top of this baseline, not a replacement for it — not scheduled.
