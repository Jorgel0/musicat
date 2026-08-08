# 0003 — Drift as the local database

## Context
The local catalog (tracks/albums/artists), playlists, and settings are
relational by nature (a playlist is an ordered set of tracks; a track
belongs to an album and an artist).

## Decision
Use Drift (over sqlite3) as the single local data store, including settings.

## Consequences
- Typed SQL and `watch()` streams integrate directly with Riverpod
  (`StreamProvider`).
- The `tracks` table has a `source` column (`local` / `soulseek`) from
  Phase 1 onward, even though it's only needed starting Phase 2 — avoids an
  awkward migration later.
- Migrations must be set up correctly from Phase 1: the schema grows every
  phase (friend/node tables in Phase 3-4), and users should never need to
  reset their local database to pick up an update.
