# 0052 — Unfriending is bidirectional (Fase 5)

## Context
ADR 0050 made the friend sync deliberately additive-only: it would add and
update, never remove. I chose that so a partial or buggy response from the
account service could not wipe someone's friend list, and I flagged the
consequence to Jorge — if Alice unfriended Bob, Bob still had Alice, still
held her cached device keys, and still treated her signed requests as a
friend's. He read that and asked for removal to propagate: *"quiero que
también desamistar sea bidireccional"*.

## Decision
The hard constraint I set for this round, and the thing not to lose:
**local removal stays instant, purely local, and unconditional.**
Propagation is layered on top; it is never a precondition. A removal that
had to wait on a network call would have broken the property that mattered
most.

- **`DELETE /accounts/<me>/friends/<accountId>`** on the account service,
  callable by **either** side, idempotent (`204` for a friendship that
  never existed, was already revoked, or names an unknown account — which
  makes retries free and keeps the route from being an enumeration
  oracle). Both accounts' devices get the existing contentless nudge, and
  only when something actually changed.
- **Revocation is a new `FriendRequestStatus.revoked`, not a deleted
  row.** The implementing agent's reasoning, which I agree with: *absence
  is what a bug produces*, so a deliberate end must look different on disk
  from a lost row. Every accepted row between the two is flipped, not just
  the first — two accounts that each sent and each accepted have two rows
  for one friendship, and leaving one behind would leave them friends
  after a revocation that reported success.
- **The removing node's `DELETE /api/v1/federation/friends/<id>` removes
  locally first**, tombstones, and only then enqueues a revocation.
  `revoke()` does two small local-disk operations and fires the send
  `unawaited` — I read it to confirm it never awaits a socket. The
  ordering is deliberate: a crash between the steps must lose the
  *propagation*, never the local removal.
- **Propagation survives being offline.** A durable
  `pending_revocations.json`, drained by the poller, at-least-once (free,
  given the idempotent route), bounded both by exponential backoff (1 min
  → 6 h) and a 30-day age cap. Age rather than an attempt count on
  purpose: a count punishes exactly the flaky-signal user this exists for.
- **The other side removes without writing a tombstone.** A tombstone
  records *this user's own* decision; being unfriended is not that, and
  tombstoning it would make a later re-friend silently fail forever, since
  `addFromAccountService` refuses tombstoned accounts. That asymmetry is
  the subtle part of this round.

## Consequences
- **My brief was wrong on one point, and an existing test caught it** — a
  good outcome, and worth recording. I said to remove "only account-based
  friends this node holds". That is not a sufficient discriminator:
  `POST /api/v1/federation/friends` writes an account-based friend when a
  peer redeems a **pairing code** and claims an accountId the service
  confirms (ADR 0049). Such a friend was never befriended *on* the account
  service, so they are absent from `GET /<me>/friends` forever — and the
  first implementation duly deleted one, failing
  `account_app_routes_test.dart`'s "logging out is not unfriending". That
  would have destroyed out-of-band trust the user set up by hand, plus the
  only address anyone had for them.
  So `Friend` gains **`confirmedByAccountService`**, decided by *which
  method wrote the entry* rather than by any caller: `add()` clears it,
  `addFromAccountService()` sets it, and `updateDevices()` promotes it. I
  checked the promotion is sound rather than assuming: all three of its
  callers act only after the account service answered `GET /<id>/devices`
  or `GET /<me>/friends`, both of which it answers only for the account
  itself or a mutual friend. The promotion is what stops every
  pre-existing `friends.json` entry being permanently un-removable while
  still defaulting to the safe answer on load.
- Gates: format and analyze clean, **547 server tests** (up from 489),
  which I re-ran myself. The agent confirmed seven separate fixes
  load-bearing by defeating each and checking that *exactly* the expected
  tests failed.

### Blast radius, stated plainly
If the account service answers `200 []` because of a bug on its side,
**every confirmed account friend on that node is dropped.** That is the
real behaviour and there is a test asserting it happens rather than hiding
it. What returns on the next correct sync: the friendship, device keys,
`displayName`, and all shared-track/playlist authorization (keyed by
accountId). What never returns: each device's locally-learned `address`
and `udpCandidate`, and the user's own `localNickname`. Untouched in all
cases: device-pinned friends, pairing-established account friends,
tombstones, and everything if the fetch merely failed.

**No sanity guard was added, deliberately.** Any threshold that refused a
suspiciously large removal would also refuse a legitimate "I removed
everyone from my other device". The one shape worth considering is
*require two consecutive syncs to agree*, costing one poll interval of
delay; it was left out because that confirmation state would be in-memory,
so a phone killed between polls might never accumulate it and would never
propagate a removal at all — trading a rare failure for a common one.
Open for Jorge to overrule.

### Operational hazard worth knowing before deploying
A `friend_requests.json` containing a `revoked` row **will not parse on a
relay binary older than this round** — `FriendRequestStatus.values.byName`
throws, and it throws for the whole file. Same forward-incompatibility
class ADR 0051 named for `RelayMessage.decode`. Rolling the relay back
past this commit means deleting revoked rows first. Deleting the row
instead of adding a status would have avoided this; it is the one real
argument for the other choice, and I kept the status because a lost row
and a deliberate end should not look alike.

### Known narrow gap, not closed
`DELETE /friends/<id>` for an id matching *no* local friend writes a
tombstone but queues no revocation — we cannot tell which account (if any)
a stale id names, and sending a raw device nodeId to the account service
would be handing it somebody else's identifier.
