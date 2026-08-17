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
- `GET /api/v1/federation/friends/<nodeId>/status` —
  `{"connected": bool, "lastSeen": "...ISO..." | null}`
- `GET /api/v1/federation/ping` — requires `X-Node-Id`/`X-Timestamp`/
  `X-Signature` headers from a trusted friend; `{"pong": true}` if valid
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
