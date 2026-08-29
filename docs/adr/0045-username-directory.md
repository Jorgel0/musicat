# 0045 — Add a friend by username, extending the relay as a directory

## Context
Third and final item of Fase 4.6 (see the plan file's own section for the
full history — ADR 0040 through 0044 built up to this). Jorge's ask: with
his Proxmox available for anything, let people add friends by username
instead of ever typing an IP address.

## Decision
- **Built as an extension of the already-deployed relay**
  (`server/lib/src/relay/relay_hub.dart`), not a separate service — the
  relay already proves "this connection really controls nodeId X" via its
  existing challenge-signature handshake (ADR 0033), so claiming a
  username piggybacks on that already-proven identity instead of needing
  a new account/password system. The nodeId/Ed25519 keypair stays the
  real trust anchor; a username is just a friendly, memorable pointer to
  one.
- **Claiming is authenticated (over the WS tunnel); looking one up is
  not (plain HTTP)** — a lookup is read-only and no more sensitive than a
  nodeId itself, which is already routinely shared via QR codes/links
  (ADR 0038). New WS message pair (`RelayClaimUsername`/
  `RelayClaimUsernameResult`) for claiming; `GET /directory/lookup?
  username=X` → `{nodeId}` or `404` for looking up, on the relay itself.
- **One username per node, first-come-first-served, persisted**
  (`UsernameDirectoryStore`, `usernames.json`, mirrors `FriendStore`'s own
  pattern) — a real deployment restart must not silently un-claim
  everyone. Re-claiming your own username is a no-op; claiming a new one
  releases whatever you had before. Format restricted to
  `^[a-zA-Z0-9_-]{3,32}$`, case-sensitive (no normalization — a known,
  accepted simplification, not a considered decision either way).
- **The pairing-code requirement is completely unchanged.** This only
  replaces "type an IP" with "type a username" for *address resolution* —
  it was never in question whether to let someone skip the target's own
  explicitly-generated, explicitly-shared pairing code, and nothing here
  does. Two new app-facing routes on the Musicat Server itself (loopback-
  only, same `requireLocal`/API-key rules as every other app-facing route,
  ADR 0044): `POST /api/v1/federation/username` (claim, via this node's
  own connected `RelayClient`) and `GET /api/v1/federation/directory/
  lookup?username=X` (resolve, against this node's own relay). The app's
  existing "Add a friend" flow (address + pairing code, unchanged) gets a
  "By username" mode: resolve a username to a `nodeId`, then address the
  *same* `addFriend()` call at `<relay-host>:<relay-port>/<nodeId>` —
  which composes with `addFriend()`'s existing `'http://$friendAddress'`
  construction into exactly the relay's own forwarding route shape
  (`<relay>/<nodeId>/<path>`), needing no new addressing mechanism at all.
- **"Choose your username" lives in the existing server-config sheet**,
  next to the relay-status row it already has — the natural home, since
  that's already where this device's own identity/relay state is shown.
  Both this and "Add by username" are hidden (not just disabled) when
  this device has no relay connected, since there's nothing to resolve
  against without one.
- **The existing QR/paste-link flow is untouched and stays available** —
  Jorge's explicit choice from the original Fase 4.6 planning: username
  lookup is an additional, more convenient path, not a replacement.

## Consequences
- `dart analyze`/`dart test` clean: server 196 → 223, app 217 → 224 —
  verified directly (diff read line by line, tests re-run myself) before
  writing this ADR, not just trusted from the implementing agents'
  reports.
- A username only ever resolves against *this node's own* currently-
  connected relay — if the target claimed theirs on a different relay,
  lookup 404s even though it's real elsewhere. Jorge's own deployed relay
  covers the common case; this is a real, known limitation for anyone
  using a different relay than their friend.
- The deployed relay (Jorge's Proxmox CT, ADR 0035) needs an operational
  update to actually persist claims across restarts — `bin/relay.dart`
  now reads `MUSICAT_RELAY_DATA_DIR` (defaults to `./data`), but the
  running systemd service was never given one; until updated, claims
  survive only until the relay process restarts (falls back to
  `InMemoryUsernameDirectory` — no data loss risk, no crash, just doesn't
  persist). Not fixed here — an operational follow-up for Jorge, not a
  code change.
- No case normalization, no username release/rename UI beyond
  "claiming a new one replaces the old," no way to pick which relay to
  resolve against from the app — all flagged as known simplifications,
  not oversights, worth revisiting if they turn out to matter in
  practice.
- With this, Fase 4.6's three items (crossed-name fix, embedded server,
  username directory) are all complete.

## QA pass (bug-hunter + feedback-critic), two real bugs found and fixed
Run per Jorge's explicit request, the first QA pass in this whole Fase
4.6 arc (items 1/2 and the security fix shipped without one — see the
Consequences note below).
- **`UsernameDirectoryStore.claim()` had a real race**: its load-mutate-
  save cycle had no locking, so two different nodes claiming the same
  username at nearly the same moment could both read the file before
  either wrote it back — both got `success: true`, but only one actually
  ended up owning it afterward, silently breaking the documented
  first-come-first-served invariant. Fixed with a plain `Future`-chaining
  mutex serializing `claim()` calls within one process (not a
  multi-process concern — a real deployment only ever runs one relay
  process against a given data directory).
- **`RelayClient.claimUsername`'s pending claim wasn't cleared on a
  tunnel drop**: if the connection dropped mid-claim, the existing
  auto-reconnect (ADR 0036) could re-establish a healthy tunnel within
  milliseconds, but a *new* claim on that healthy tunnel still got
  rejected with a misleading "already in progress" error for up to the
  full 10-second internal timeout, because nothing told the stale claim
  it was already dead. Fixed by having the same drop-detection that
  already clears `_channel` and schedules reconnection also fail any
  pending claim immediately — mirroring `RelayHub.disconnect()`'s
  existing precedent of not making callers wait out a timeout for
  something already known to be gone.
- Both confirmed with real repros before fixing (concurrent `claim()`
  calls on a real `UsernameDirectoryStore`; a real `RelayClient`/
  `RelayHub` pair with a tunnel dropped mid-claim), and regression tests
  added proving each fails pre-fix and passes post-fix. Server test count
  223 → 228.
- feedback-critic independently flagged the same disconnect-handling gap
  from reading the code alone (before bug-hunter's repro confirmed it) —
  a good sign the QA process is catching real things, not just agreeing
  with itself.
- feedback-critic also raised two things not fixed in this pass, worth a
  conscious decision rather than silent scope creep: (1) `addFriend()`
  has always hardcoded `http://` regardless of whether a relay is
  `ws://` or `wss://` (pre-existing since ADR 0032/0033, not introduced
  here) — this commit is what turns that from a rare fallback path into
  the routine "add a friend" flow, so a `wss://`-fronted relay's traffic
  would silently downgrade to plaintext; (2) there is no way in the app
  for a user to see their own currently-claimed username before
  overwriting it by claiming a new one (`MyNodeInfo` has no `username`
  field, and the relay has no reverse-lookup-by-nodeId route). Neither
  is fixed here — flagged for a decision on prioritization.

## Consequences (QA scope)
This QA pass covered only this item (commit `84a1ed2`). The three prior
Fase 4.6 commits — the crossed-name fix, the embedded server on both
platforms, and the loopback-restriction security fix — shipped without
a bug-hunter/feedback-critic pass. feedback-critic explicitly pushed
back on treating this item's clean result as reassurance about those:
the embedded-server work touches exactly the kind of process-lifecycle/
platform-specific-startup territory this project's own history (the
`IOWebSocketChannel` double-error bug, two separate Riverpod-lifecycle
crashes) says tends to hide bugs until poked at adversarially, and the
loopback-restriction fix is a security control whose failure mode is
silent by nature — a bypass wouldn't crash, it would just quietly work.
Not addressed in this ADR; a decision for Jorge on whether/when to run
that QA retroactively.
