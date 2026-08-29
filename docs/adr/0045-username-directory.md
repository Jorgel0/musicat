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
  username directory) are all complete. Next: a `/dev-team` QA pass
  (`bug-hunter` + `feedback-critic`) on the whole item, per Jorge's
  explicit request — not yet run as of this commit.
