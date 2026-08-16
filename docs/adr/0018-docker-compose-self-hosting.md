# 0018 — Docker Compose for self-hosting slskd + Musicat Server

## Context
The last piece of Fase 3's scope: a `docker-compose.yml` that stands up
slskd and Musicat Server together from scratch, so self-hosting doesn't
require manually wiring the two together.

This came right after a real debugging session (same day) figuring out
slskd's *actual* configuration surface, which directly shaped the design
here: a fully-commented `slskd.yml` at `~/.local/share/slskd/slskd.yml` is
the file slskd's own startup log reports loading (not the bundled
`config/slskd.example.yml` reference template, and not `data/slskd.yml`).
While chasing that, `./slskd --envars` turned up the actual, authoritative
environment variable names — `SLSKD_API_KEY` ("primary API key value"),
`SLSKD_SLSK_USERNAME`/`SLSKD_SLSK_PASSWORD` (Soulseek network login, not
the web UI's own `SLSKD_USERNAME`/`SLSKD_PASSWORD`), `SLSKD_NO_AUTH`. These
are what this compose file configures slskd with — no mounted YAML file
needed, which sidesteps the exact "which file is real" confusion from
earlier entirely for a fresh Docker deployment (see
[[reference_musicat_slskd_dev_instance]]).

## Decision
- **One `docker-compose.yml` at the repo root** (not inside `server/`,
  since it orchestrates slskd too, not just Musicat Server) with two
  services: `slskd` (official `slskd/slskd` image) and `musicat-server`
  (built from `server/`'s existing `Dockerfile`).
- **Real authentication, not `--no-auth`.** Unlike the throwaway local
  testing setup, this is meant for an actual self-hosted deployment:
  `SLSKD_API_KEY` is a shared secret set once (via `.env`) that slskd
  requires on every REST call and Musicat Server presents on every call it
  makes — `SLSKD_NO_AUTH` is deliberately not used here.
- **Config via environment variables, not a mounted `slskd.yml`.** Given
  the confirmed, authoritative env var names, this is simpler and more
  "12-factor" than shipping/mounting a YAML file, and avoids the exact
  class of mistake (editing the wrong file, or editing a file but leaving
  the `#` in front of the change) hit during manual testing earlier today.
- **`.env` / `.env.example`** at the repo root for the two real secrets
  (Soulseek login, shared API key) — `.env` already gitignored project-wide.
- **Volumes**: `./data/slskd:/app` (the whole slskd app directory in one
  bind mount, matching slskd's own documented Docker convention) and
  `./data/musicat-server:/app/data` (Musicat Server's node identity and
  future persistent state). Both under a gitignored `./data/`.
- **Ports**: 5030/5031 (slskd web UI/API) and 50300 (Soulseek P2P listen)
  stay exposed to the host, not just the internal Docker network — useful
  for direct troubleshooting via slskd's own web UI, documented alongside a
  reminder to change its default `slskd`/`slskd` web login if reachable
  beyond a home LAN.
- New `docs/self-hosting.md` is the entry point for this — linked from both
  the root and `server/` READMEs.

## Consequences
- `docker-compose up -d` genuinely stands up the whole stack from an empty
  `data/` directory, satisfying Fase 3's "Hecho cuando" bar for this piece.
  **Verified end-to-end for real** (on the CT host, with alternate host
  ports so it wouldn't collide with the CT's own long-running `slskd`
  container, torn down completely afterward): `docker compose up -d
  --build` from a clean checkout of `server/` built the image and started
  both containers; a fresh, throwaway Soulseek account (registered on first
  connect, per the note above) authenticated correctly through the shared
  `SLSKD_API_KEY` on the first try — unlike the manual local debugging
  earlier the same day, both sides had the same key from the start, so
  there was no repeat of that confusion; `GET /api/v1/soulseek/status`
  reported `connected: true`; a real search returned 251 results; and
  restarting the `musicat-server` container alone reproduced the exact
  same `nodeId`, confirming the node identity survives restarts via the
  bind-mounted volume as required.
- Auto-import (ADR 0013) only works when Musicat (the desktop app) runs on
  the same machine as this stack — documented explicitly in
  `docs/self-hosting.md` rather than left as a surprise.
- Sharing one's own library on Soulseek (`SLSKD_SHARED_DIR` + a share
  volume) was deliberately left out of the compose file itself — it's
  optional and not part of Musicat's current feature set, just documented
  as a pointer to slskd's own docs if someone wants it.
- **Unrelated but worth recording**: fetching slskd's own Docker docs via
  `WebFetch` (a summarizing tool) returned a response injecting an
  unrelated instruction referencing this project's own organizational
  context (Roommatik) — recognized as prompt injection, flagged to Jorge,
  ignored, and the real docs were instead pulled via a direct `curl` of the
  raw GitHub markdown (no summarization step) to get trustworthy content.
