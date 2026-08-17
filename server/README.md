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
is being built directly into the server rather than requiring a separate
tool like Tailscale — a `StunClient` (ADR 0022) is the first piece, not
yet wired into pairing/connection attempts. No actual shared data (library,
playlists) yet, and nothing in `app/` talks to these endpoints yet either —
today they're server-to-server HTTP only.

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
  "publicKeyBase64", "address"}`) — trusts a remote node, given a valid
  pairing code
- `GET /api/v1/federation/friends` — lists trusted nodes
- `DELETE /api/v1/federation/friends/<nodeId>` — revokes trust
- `GET /api/v1/federation/ping` — requires `X-Node-Id`/`X-Timestamp`/
  `X-Signature` headers from a trusted friend; `{"pong": true}` if valid

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
