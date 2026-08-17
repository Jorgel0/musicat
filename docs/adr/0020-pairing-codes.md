# 0020 — Pairing codes close the friend-registration gap

## Context
ADR 0019 built the signed request/friend-verification trust model but
deliberately left `POST /api/v1/federation/friends` (registering a new
friend) completely unprotected — anyone who could reach a node's HTTP API
could add themselves as a trusted friend. That's a real hole: it's the one
endpoint that *grants* trust, so it needs its own gate before anything
built on top of the trust model (shared library, joint playlists) means
anything.

## Decision
- **`PairingCodeStore`**: generates short-lived (10 minutes), single-use
  codes — 24 random bytes, hex-encoded, sized for a QR code or copy-paste
  link rather than manual digit-by-digit typing, matching the plan's
  "emparejamiento... fuera de banda (QR/código)". Kept in memory (not
  persisted) — a code is meant to live minutes, not survive a restart.
- **`POST /api/v1/federation/pairing-codes`** generates one. **`POST
  /friends`** now requires a `code` field; it's redeemed (and consumed,
  whether or not the rest of the request succeeds) via
  `PairingCodeStore.redeem` before the friend is actually added. An
  invalid, expired, or already-used code → `403`.
- Redemption always removes the code, even mid-request-validation, so a
  code can never be redeemed twice regardless of what else fails about the
  request that tried to use it — there's no path where a code survives an
  attempt to use it.
- Neither `/pairing-codes` nor `/friends` sits behind `RequestVerifier`
  (ADR 0019) — by definition, there's no existing friendship to check
  against for either the node *offering* a code or the node *redeeming*
  one to become a friend for the first time.

## Consequences
- Unit-tested (`PairingCodeStore` alone: generation, single-use, unknown
  codes, TTL expiry; the route layer: missing/unknown/reused codes all
  rejected, a valid one succeeds).
- **Verified for real, end to end, across two running server processes**:
  confirmed a registration attempt with no code fails (`400`), Server B
  generated a real code via its own `POST /pairing-codes`, Server A used
  it to register itself as B's friend (`201`), immediately reusing that
  same code failed (`403`), and — the actual point of all this — a real
  `RequestSigner`-signed ping from A, using the identity it registered
  with, was accepted by B (`200 {"pong": true}`) purely on the strength of
  that one-time code, with no other channel involved.
- This closes ADR 0019's flagged gap. Still open, deliberately not
  decided here: the actual pairing *UX* (how a code becomes a QR code or
  link two humans exchange, and how the app calls these endpoints at all —
  today they're server-to-server HTTP only, nothing in `app/` talks to
  them yet), and NAT traversal (still untouched — this was verified
  between directly-reachable processes only).
