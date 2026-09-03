# 0048 — A real, portable account service (Fase 5, foundation)

## Context
After Fase 4.6 shipped and was verified for real (ADR 0047), Jorge gave
direct product feedback: the whole Friends section is "super tediosa,"
and he wants two things specifically — real, portable accounts
(username + password, hosted on his own Proxmox, "es todo mío") that
survive a reinstall or a new device, and real friend *requests*
(send/accept, not two separate one-directional pairing-code
redemptions). Designed with a dedicated Plan pass given how much this
touches the existing trust model — see the plan file's "Fase 5" section
for the full design writeup and the security risks flagged there
explicitly (revocation-propagation lag, the new password attack
surface, a weaker identity guarantee than pairing codes provide).

This ADR covers the **foundation only**: the account service itself
(signup/login/device-linking, device management, and the friend-request
*data model* with plain HTTP send/list/accept/decline). It does **not**
yet touch `FriendStore`/`RequestVerifier` (nothing in the existing
sharing/playlist trust model consumes accounts yet), does not add
push-delivery over the relay tunnel, and has no app UI — all separate,
later rounds per the plan's stated delivery order.

## Decision
- **New module `server/lib/src/accounts/`**, mounted as its own router
  (`/accounts/`) on the **same deployed relay process/port** as
  `RelayHub`, registered *before* `RelayHub`'s own catch-all forwarding
  route (same route-ordering care as ADR 0045's `/directory/lookup`) —
  but kept as clearly separate code/tests from `RelayHub` itself:
  passwords are a categorically more sensitive secret than anything the
  relay has ever had to protect, and keeping the modules separable means
  a review of one doesn't have to re-audit the other.
- **Argon2id** password hashing (`package:cryptography`, no new
  dependency), OWASP's second published configuration (19 MiB memory, 2
  iterations, 1 lane — chosen for a small self-hosted box with no
  guaranteed spare memory per concurrent login), ~200ms/hash on ordinary
  hardware. Cost parameters are stored **per account**, not a single
  global constant, so they can be raised later for new accounts without
  invalidating existing ones.
- **A device proves "I act for account X" by reusing its own existing
  Ed25519 key, not a session token** — the same challenge-nonce shape
  already used by the relay's own connection handshake and by federation
  request signing. No new bearer secret to protect or expire.
- **Signup and login are the same wire flow** (`POST /login/start` →
  nonce, `POST /login/complete` → username + password + nodeId +
  publicKey + signature over the nonce): a brand-new username creates
  the account and links this device as its first; an existing username
  verifies the password and links this device as an *additional* one
  (idempotent if already linked) — **multiple devices per account, live
  simultaneously**, matching Jorge's own real usage (phone + home
  desktop, both active at once) and costing nothing extra in the
  verification model, which already has to handle a set of valid device
  keys either way.
- **Account enumeration**: `login/start` does identical work regardless
  of whether the username exists, so its shape/timing leak nothing.
  `login/complete`'s outcome can eventually distinguish existence, but
  only after a real Ed25519 proof-of-key-control per attempt — a much
  higher bar than a cheap repeatable query.
- **Rate limiting from day one, not deferred**: 5 consecutive wrong
  passwords for a username locks it out for 60 seconds.
- **Device unlinking** (`DELETE /<accountId>/devices/<nodeId>`) is
  authenticated the same signed-request way, and any linked device can
  unlink any other device on the same account (remote-revoke a lost
  phone from your desktop) — the real recovery mechanism for a
  lost/stolen device, shipped alongside multi-device support, not after.
- **Real friend requests, data model + HTTP only this round**: send
  (`POST /<me>/friend-requests {toUsername}`), list pending (`GET
  /<me>/friend-requests?status=pending`), accept/decline. Accepting is
  the one action that establishes mutual trust for both accounts —
  directly answering Jorge's "two separate pairings is tedious"
  complaint, once a later round wires this into the actual friend/UI
  flow.
- **`GET /<accountId>/devices`** (the full device list, needed by a
  later `RequestVerifier` round to resolve a friend's current keys) is
  gated to mutual friends only (an `accepted` request in either
  direction) — deliberately tighter than ADR 0045's fully-open username
  lookup, since a full device list discloses meaningfully more than one
  nodeId pointer. An account can always see its own list.
- **Existing pairing codes and the username directory (ADR 0045) are
  untouched and keep working** — this is new, additional infrastructure
  for the account-based flow, not a replacement.

## Consequences
- `dart analyze`/`dart test` clean, 304 tests (up from 228) — reviewed
  the actual diff line by line before running anything myself, not just
  trusted the implementing agent's report; specifically re-verified the
  Argon2id usage (real random per-account salt, constant-time compare,
  per-account stored parameters) and the signed-request path resolution
  (`request.requestedUri.path`, matching the exact pattern
  `federation_routes.dart`'s own `GET /ping` already uses) directly
  against the source.
- `AccountRequestVerifier` is a small, deliberate duplicate of
  `RequestVerifier`'s shape (same canonical-string signing, different
  key source — an account's linked devices instead of `FriendStore`) —
  expected to unify once a later round makes the account service the
  sole source of device identity for federation trust too.
- Nothing yet consumes this service — `FriendStore`/`RequestVerifier`
  still resolve trust exactly as before ADR 0048. That's the next round.
- Two accounts that each send the other a pending request are *not*
  automatically mutual friends — each still has to explicitly accept
  the other's incoming request. A deliberate, simple rule, not
  optimized away, worth knowing about before building the app UI around
  it.
- Rate limiting is username-scoped only, not IP-scoped — a reasonable
  v1 given each attempt already costs a full nonce+signature round
  trip, flagged as a possible future tightening rather than done here.
