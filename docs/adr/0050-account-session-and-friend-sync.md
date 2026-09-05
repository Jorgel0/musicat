# 0050 — A node that knows whose account it is (Fase 5, item 3 round A)

## Context
ADR 0048 built the account service (accounts, devices, friend requests).
ADR 0049 made an *account* the unit of local federation trust. Nothing
connected the two: accepting a friend request changed nothing in any
node's `FriendStore`, and a node had no idea which account it acted for.

Reading the code before briefing this round turned up two prerequisites
that the plan's one-line item-3 entry doesn't mention, and that have to
exist before push or polling means anything:

- **No local account session at all.** A node couldn't call
  `/accounts/<me>/anything`, because it didn't know who `<me>` was.
- **The account service could only list *incoming* requests**
  (`listAddressedTo`). There was no way to ask "who am I actually friends
  with", which is what a node needs to sync.

So item 3 splits: **round A (this ADR) builds the bridge**; round B adds
push over the relay tunnel, the polling fallback, and the app-facing
friend-request routes.

## Decision
- **`AccountSessionStore`** persists `{accountId, username, loggedInAt}`
  to `account_session.json`. **The password is never stored** — after
  login this device authenticates with its own Ed25519 key, which is why
  a stolen phone compromises that device (revocable by unlinking it) and
  not the account.
- **Node-side app routes** `POST/GET/DELETE /api/v1/account/*`, all
  `requireLocal` like every other app-facing route (ADR 0044). Logout
  clears the session and **deliberately leaves `FriendStore` alone**:
  logging out is not unfriending.
- **`GET /accounts/<me>/friends`** on the account service returns every
  accepted counterparty with their devices inlined. The disclosure is
  provably the same one `GET /<accountId>/devices` already makes to the
  same caller — both gated on `areMutualFriends` — so inlining saves a
  signed round trip per friend without widening anything. I re-read the
  route to confirm the gate really is equivalent rather than taking it on
  trust, and it is: it returns only accounts with an accepted request
  with `<me>`, carrying no password material.
- **`FriendSyncService`** reconciles that list into the local
  `FriendStore`. Three rules, each with a test that fails without it:
  never resurrect a tombstoned account; never touch a legacy
  device-pinned friend; never adopt yourself.
- **The sync is additive-and-updating only — it never removes.** A
  partial or buggy response from the account service must not be able to
  wipe someone's friend list, and unfriending stays a deliberate local
  act. Stated limitation, not an oversight: if someone unfriends you on
  the account service, your local entry survives until you remove it.

## Consequences
- `FriendStore.addFromAccountService()` is new API the implementing agent
  added beyond the brief, and it was right to. My brief said "check
  `isRemoved` first", which is a TOCTOU when done caller-side: `add()`
  *clears* tombstones, so a `remove()` landing between the check and the
  add would erase the tombstone and restore the friend with their keys —
  the same race ADR 0049 fixed in `updateDevices`. The check now lives
  inside the store's own lock. It also refuses to overwrite an existing
  entry or displace a device-pinned one, keeping the legacy→account
  migration behind an explicit re-pair where ADR 0049 put it.
- Verified rather than trusted: I re-ran all three gates myself (**435
  server tests**, up from 378; 231 app tests; analyze and format clean),
  read the reconcile loop and the new route's authorization gate, and
  confirmed the two load-bearing tests are load-bearing by deleting both
  tombstone checks and watching exactly those two tests — and no others —
  fail, then restoring.

### The real product gap this exposes, named rather than hidden
**Two people who become friends purely through the account service
cannot reach each other at all.** `DeviceLink` records `nodeId`,
`publicKeyBase64` and `linkedAt` — no address, no relay. So a synced
friend has zero reachability candidates, and browsing them fails fast and
cleanly (`502 Friend unreachable`, ~6ms, no hang) rather than crashing —
but it fails. Each side can *verify* the other's incoming signed
requests; neither can *initiate*.

That makes "add a friend by username" produce, today, a friend you can't
actually use — precisely the experience Fase 5 exists to remove. It is
structural, not a bug: I confirmed it by reading `DeviceLink` rather than
inferring it from the symptom.

The closure is cheap and belongs in round B: **the account service should
record each device's relay URL**, supplied by the node at login (the node
already knows its own configured relay). A synced friend then gets a
relay candidate and `reachFriend` routes `<relay>/<nodeId>/<path>` — the
exact ADR 0033 mechanism already proven across real networks in ADR 0035
and 0047. It discloses nothing new: `relayUrl` is already exchanged at
pairing time today. `mergeFriendDevices` will need to prefer a
locally-learned relay but fall back to the authoritative one, which it
currently cannot do (it takes reachability *only* from the local cache,
on the assumption the account service records none).

## Deliberately not in this round
Relay push and the polling loop (round B — `FriendSyncService` owns no
timer and nothing runs it on a schedule yet; only login triggers one).
No UI. Account-service-side unfriending still does not propagate.
