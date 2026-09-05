# Musicat Server

Musicat Server is the self-hosted backend that wraps [slskd](https://github.com/slskd/slskd)
and, starting in Phase 4, powers federated friend-to-friend playlist and
library sharing. See [`docs/architecture.md`](../docs/architecture.md) and
`docs/adr/` in the repo root for the overall design.

Licensed under [AGPL-3.0](LICENSE) — see the root [`README.md`](../README.md)
for why this differs from the app's MIT license.

## Status

Phase 3 is done: a `shelf`-based HTTP server with a persistent **node
identity** (an Ed25519 keypair; `nodeId` is the SHA-256 fingerprint of the
public key, hex-encoded), and a wrapper around a self-hosted **slskd**
instance (ADR 0016) that the app can talk to instead of slskd directly
(ADR 0017, opt-in via Settings — direct slskd is still fully supported
too), with a `docker-compose.yml` to self-host the whole thing (ADR 0018).

Phase 4 (federated friend-sharing), in progress: nodes sign and verify
requests to each other using their node identity (ADR 0019), and joining
as a friend requires a short-lived, single-use pairing code (ADR 0020) —
the trust primitive future federation features sit behind. NAT traversal
(so two friends on different home networks can actually reach each other)
is built directly into the server rather than requiring a separate tool
like Tailscale: pairing exchanges each side's STUN-discovered UDP address,
attempts a hole-punch, and then keeps it alive with periodic signed
packets (ADR 0022/0023/0024) — verified working (including staying
connected over an extended real test) between two real server processes,
though not yet across a real NAT boundary. The actual sharing mechanism
(ADR 0025): a node exposes chosen tracks' *metadata* (title/artist/cover)
— never a whole library — to either one specific friend or all of them,
and the recipient downloads the real file directly, peer-to-peer, only if
they're actually authorized for that track. Joint playlists (ADR 0026)
build on the same mechanism: each participant adds their own tracks, and
`/sync` pulls the others' contributions in via a per-item union (not
whole-object last-write-wins, so concurrent additions from both sides
never get lost) — verified with two real servers syncing back and forth.
Nothing in `app/` talks to any of this yet — no share button, no
profile/playlist UI, no invite flow — today it's all
server-to-server/local-API only.

Endpoints so far:
- `GET /` — health check (`{"status": "ok"}`)
- `GET /api/v1/node` — this node's identity
  (`{"nodeId": "...", "publicKeyBase64": "..."}`)
- `GET /api/v1/soulseek/status` — `{"connected": bool}`
- `POST /api/v1/soulseek/searches` (`{"query": "..."}`) — starts a search,
  returns `{"searchId": "..."}`
- `GET /api/v1/soulseek/searches/<id>` — the search's current state/results
- `DELETE /api/v1/soulseek/searches/<id>` — cancels a search
- `POST /api/v1/soulseek/downloads` (`{"username", "files": [...]}`) —
  enqueues a download
- `GET /api/v1/soulseek/downloads` — the current transfer queue
- `DELETE /api/v1/soulseek/downloads/<username>/<id>` — cancels a download
- `GET /api/v1/soulseek/downloads-directory` — where slskd saves completed
  downloads (`{"directory": "..." | null}`)
- `POST /api/v1/federation/pairing-codes` — generates a 10-minute,
  single-use code (`{"code": "..."}`) to hand a friend out-of-band
- `POST /api/v1/federation/friends` (`{"code", "nodeId",
  "publicKeyBase64", "address", "udpCandidate"?}`) — trusts a remote node,
  given a valid pairing code; returns this node's own current
  `udpCandidate`, and triggers a background NAT hole-punch attempt toward
  the caller's if one was provided
- `GET /api/v1/federation/friends` — lists trusted nodes
- `DELETE /api/v1/federation/friends/<nodeId>` — revokes trust and stops
  maintaining its NAT keepalive
- `PATCH /api/v1/federation/friends/<nodeId>` (`{"localNickname": "..." |
  null}`) — sets/clears a purely local label for that friend (never sent
  to them, distinct from the `displayName` they report about
  themselves); 404 if `nodeId` isn't a known friend
- `GET /api/v1/federation/friends/<nodeId>/status` —
  `{"connected": bool, "lastSeen": "...ISO..." | null}`
- `GET /api/v1/federation/ping` — requires `X-Node-Id`/`X-Timestamp`/
  `X-Signature` headers from a trusted friend; `{"pong": true}` if valid
- `POST /api/v1/account/login` (`{"username", "password"}`) — logs this
  node in to a portable account on the configured account service (creating
  it if that username is free), links this device to it, and immediately
  syncs the account's accepted friendships into the local friend list before
  answering; `{"accountId", "username", "created": bool}`. `401` on a wrong
  password, `429` when the account service is rate-limiting that username,
  `503` if the account service is unreachable or none is configured on this
  node. The password is never stored: from here on this device proves it
  acts for the account by signing with its own node key.
- `GET /api/v1/account` — `{"account": {"accountId", "username",
  "loggedInAt"} | null}`; answered from local disk, so it works with the
  account service down
- `DELETE /api/v1/account` — logs out (`204`, idempotent). Clears the
  session only — friends are local trust and are deliberately left
  untouched
- `GET /api/v1/account/friend-requests` — the friend requests currently
  addressed to this account and still pending: `{"requests": [{"id",
  "fromAccountId", "fromUsername", "toAccountId", "toUsername", "status",
  "createdAt"}], "fetchedAt": "...ISO..." | null, "live": bool}`. Fetched
  live when the account service is reachable (`"live": true`); otherwise
  the last list this node saw, with `"live": false`. A `null` `fetchedAt`
  means this node has never managed a fetch — an empty list it cannot
  vouch for, as opposed to a confirmed empty one
- `POST /api/v1/account/friend-requests` (`{"toUsername"}`) — sends a
  friend request by username; `201` with the created request. Sending
  again while one is still pending returns the existing one rather than
  creating a second. `404` if that username has no account
- `POST /api/v1/account/friend-requests/<id>/accept` and `.../decline` —
  answers one; `200` with the updated request. Accepting immediately syncs
  the new friendship into the local friend list before answering, so
  `GET /api/v1/federation/friends` already reflects it. `403` if this
  account isn't the request's recipient, `404` for an unknown id, `409` if
  it was already answered
- `POST /api/v1/library/shared-tracks` (`{"filePath", "title", "artist",
  "album"?, "coverArtPath"?, "visibility": {"type": "friends", "nodeIds"} |
  {"type": "allFriends"}}`) — shares a local file's metadata
- `GET /api/v1/library/shared-tracks` — lists what this node shares
- `DELETE /api/v1/library/shared-tracks/<id>` — stops sharing it
- `GET /api/v1/sharing/shared-tracks` — (friend-signed) what's shared with
  the caller
- `GET /api/v1/sharing/shared-tracks/<id>/file` /
  `.../cover` — (friend-signed) downloads the real file/cover bytes, only
  if shared with that specific caller
- `POST /api/v1/library/playlists` (`{"id"?, "name",
  "participantNodeIds"}`) — creates a joint playlist, or joins an
  existing one if `id` is supplied
- `GET /api/v1/library/playlists` / `GET .../<id>` — this node's own
  local view
- `POST /api/v1/library/playlists/<id>/items` (`{"filePath", "title",
  "artist", "album"?, "coverArtPath"?}`) — adds one of this node's own
  tracks (auto-shares it with the other participants)
- `DELETE /api/v1/library/playlists/<id>` — deletes this node's local copy
- `POST /api/v1/library/playlists/<id>/sync` — pulls every participant's
  current view and merges it in
- `GET /api/v1/sharing/playlists/<id>` — (friend-signed) this node's
  current view, for a participant's server to sync

Configure the slskd connection with `SLSKD_HOST` (default `localhost`),
`SLSKD_PORT` (default `5030`), and `SLSKD_API_KEY`.

## Running with the Dart SDK

```
$ dart run bin/server.dart
Node identity: <64-char hex nodeId>
Server listening on port 8080
```

```
$ curl http://0.0.0.0:8080/
{"status":"ok"}
$ curl http://0.0.0.0:8080/api/v1/node
{"nodeId":"..."}
```

Configuration is via environment variables:
- `PORT` — HTTP port (default `8080`).
- `MUSICAT_DATA_DIR` — where the node identity (and future persistent state)
  is stored (default `./data`). Back this with a volume in production —
  losing it changes the node's identity.
- `MUSICAT_UDP_PORT` — local UDP port for NAT hole-punching (default:
  random, OS-assigned). Set this and forward it on your router if you
  want a stable, predictable port for federation traversal.
- `MUSICAT_APP_API_KEY` — a shared secret (default: unset) that lets a
  non-loopback caller reach the app-facing routes below (Soulseek
  config/search, friend management, library/shared-track management,
  joint playlists) — these normally only accept requests from this exact
  machine's own loopback interface. Only needed if you're running this
  server on a separate machine from the app (see
  [`docs/self-hosting.md`](../docs/self-hosting.md)); leave unset for the
  now-default case of the app embedding its own local server, which is
  always loopback and never needs this. When set, a non-loopback request
  must present the same value in an `X-Api-Key` header, or it gets `403`
  exactly as it would with no key configured at all.
- `MUSICAT_ACCOUNT_SERVICE_URL` — the portable account service to consult
  (default: unset), e.g. `http://relay.example.com:8090/accounts` — the
  same deployed relay process, under its `/accounts` prefix. Entirely
  optional: unset, this server behaves exactly as it did before accounts
  existed (device-pinned friends only). When set, it is still never on
  the path of a normal request between two already-established friends —
  it is consulted only when an incoming request comes from a device this
  server has never heard of (rate-limited), on the periodic refresh of a
  friend account's device list (every 30 minutes), on the periodic refresh
  of this account's own friends and pending friend requests (every 5
  minutes), when a peer redeeming a pairing code claims to belong to an
  account, when this node's own user logs in or answers a friend request,
  and when the relay nudges this node that something changed. Two friends
  on the same network can always share with it down, logged in or not, and
  **a node that never logs in never contacts it at all** — the periodic
  refreshes do nothing without a session.

  Logging in also publishes this node's own relay URL (`MUSICAT_RELAY_URL`,
  if it connected to one) to the account service, so that people who become
  friends purely through a friend request — with no pairing and therefore no
  address for each other — can still reach each other through it. That
  discloses which relay you use to your mutual friends, and to nobody else;
  it is the same thing already exchanged when pairing directly. A node with
  no relay configured publishes nothing and stays reachable only at whatever
  address a friend already has for it.

## Running with Docker

```
$ docker build . -t musicat-server
$ docker run -it -p 8080:8080 -v musicat-data:/app/data musicat-server
```

To run this alongside slskd in one step, see
[`docs/self-hosting.md`](../docs/self-hosting.md) (`docker-compose up` at
the repo root).

## Development

```
$ dart pub get
$ dart analyze
$ dart test
```
