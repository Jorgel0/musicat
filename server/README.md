# Musicat Server

Musicat Server is the self-hosted backend that wraps [slskd](https://github.com/slskd/slskd)
and, starting in Phase 4, powers federated friend-to-friend playlist and
library sharing. See [`docs/architecture.md`](../docs/architecture.md) and
`docs/adr/` in the repo root for the overall design.

Licensed under [AGPL-3.0](LICENSE) — see the root [`README.md`](../README.md)
for why this differs from the app's MIT license.

## Status

Phase 3, in progress: a `shelf`-based HTTP server with a persistent **node
identity** (an Ed25519 keypair; `nodeId` is the SHA-256 fingerprint of the
public key, hex-encoded — the foundation the Phase 4 federated trust model
will build on), and a wrapper around a self-hosted **slskd** instance
(ADR 0016) so the app can eventually search/download through this server
instead of talking to slskd directly.

Endpoints so far:
- `GET /` — health check (`{"status": "ok"}`)
- `GET /api/v1/node` — this node's identity (`{"nodeId": "..."}`)
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

Configure the slskd connection with `SLSKD_HOST` (default `localhost`),
`SLSKD_PORT` (default `5030`), and `SLSKD_API_KEY`.

Not yet implemented: the app actually talking to this server (it still
talks to slskd directly), or anything federation-related.

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

## Development

```
$ dart pub get
$ dart analyze
$ dart test
```
