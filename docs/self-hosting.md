# Self-hosting Musicat's backend

This runs the whole Soulseek backend — [slskd](https://github.com/slskd/slskd)
plus [Musicat Server](../server/README.md), which wraps it behind a stable
API (see ADR [0016](adr/0016-server-wraps-slskd.md)/
[0017](adr/0017-app-musicat-server-client.md)) — with one command. The
Musicat app then points at Musicat Server from Settings → Soulseek backend.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose.
- A Soulseek account. You don't need to sign up anywhere first — the
  username/password you choose below is registered automatically the first
  time slskd connects with it, as long as the name isn't already taken.

## Setup

1. Copy the environment template and fill it in:
   ```
   cp .env.example .env
   ```
   - `SLSKD_SLSK_USERNAME` / `SLSKD_SLSK_PASSWORD` — your Soulseek login.
   - `SLSKD_API_KEY` — a shared secret between slskd and Musicat Server.
     Generate one with `openssl rand -hex 32` (or `docker run --rm
     slskd/slskd:latest --generate-secret 32`).
   - `MUSICAT_APP_API_KEY` — only needed if the app will reach this stack
     over the real network rather than running on the same machine (see
     step 3 below). Generate one the same way: `openssl rand -hex 32`.

2. Start the stack:
   ```
   docker-compose up -d
   ```
   This creates `./data/slskd/` and `./data/musicat-server/` next to this
   file to persist state across restarts — in particular, Musicat Server's
   node identity (ADR 0015) and slskd's own database/downloads.

3. In the Musicat app, go to **Settings → Soulseek backend**, select
   **Musicat Server**, and set the host/port to wherever this stack is
   reachable (`localhost:8080` if it's running on the same machine as the
   app). If this stack is running on a *different* machine than the app
   (a NAS or VPS, say) rather than `localhost`, also set the API key you
   generated for `MUSICAT_APP_API_KEY` above in the same settings screen —
   without it, this server rejects every request that doesn't arrive from
   its own machine, by design (see "Remote access" below). Tap **Test
   connection** to confirm.

## Remote access

By default, Musicat Server only accepts requests from its own machine —
this is what makes the common case (the app embedding its own local
server, needing no setup at all) safe by default. Pointing the app at a
Musicat Server running somewhere else, as described in step 3 above, is
the one case where this needs to be relaxed: set `MUSICAT_APP_API_KEY` in
`.env` (a random secret, generated the same way as `SLSKD_API_KEY` above)
and configure that *same* key in the app's Musicat Server settings. A
request without the right key still gets rejected exactly as before. If
you're only ever going to run the app on the same machine as this stack,
you don't need to set this at all.

## Notes

- **slskd's web UI** is reachable at `http://<host>:5030`, logged in with
  `SLSKD_USERNAME`/`SLSKD_PASSWORD` (default `slskd`/`slskd` — set your own
  in `.env` if this is reachable beyond your own LAN).
- **Sharing your own library on Soulseek** (optional, not required for
  Musicat to work) needs a bind-mounted directory and `SLSKD_SHARED_DIR` —
  see slskd's own [Docker docs](https://github.com/slskd/slskd/blob/master/docs/docker.md)
  for the exact volume/env var shape.
- **Auto-import of finished downloads** (ADR 0013) only works when Musicat
  runs on the *same machine* as slskd — slskd has no way to hand a
  downloaded file's bytes to a different device. If Musicat runs elsewhere,
  search/download through Musicat Server still works; only the
  automatic-import step won't find the files.
- To stop the stack: `docker-compose down` (add `-v` to also delete the
  persisted data — this changes Musicat Server's node identity and forgets
  slskd's cache/database).
