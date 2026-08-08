# core/database

Phase 1: the Drift (`AppDatabase`) schema — the single local source of truth
for the track/album/artist catalog, playlists, and settings. Tracks carry a
`source` column (`local` / `soulseek`) from the start, ahead of Phase 2.
