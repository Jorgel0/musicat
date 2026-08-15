# 0011 — Group search results by artist/album/song, not by peer

## Context
The first Search screen implementation showed slskd's raw response shape:
a list of peers, each with the files they have matching the query. Jorge's
feedback after trying it: he wants results organized the way the rest of
the app (and every other music app) organizes things — by artist, album,
and song — not by which stranger's computer happens to be sharing a copy.

Soulseek gives no real metadata for a search result: just a remote file
path (e.g. `@@user\Music\Daft Punk - Discovery (2001)\03 - Digital
Love.mp3`) and, sometimes, embedded audio properties (bitrate, duration).
There's no tag data on the wire at all — unlike the local library scanner,
which reads real ID3/Vorbis tags from files it can open directly.

## Decision
- Parse artist/album/title from the remote path alone
  (`core/network/soulseek/soulseek_filename_parser.dart`): the immediate
  parent folder is assumed to be `"Artist - Album"` (optionally with a
  `(Year)`/`[Year]` marker, which is stripped), and the filename (minus
  extension and a leading track number) becomes the title. No separator
  in the folder name means the artist can't be told apart from the album,
  so it falls back to "Unknown artist" with the whole cleaned folder name
  as the album.
- Group parsed results across every peer response into Artist > Album >
  Song (`features/search/domain/group_search_results.dart`), keyed on the
  lowercased parsed artist+album+title. Each song keeps every peer
  offering it as a `source`, so the same song from multiple peers/qualities
  collapses into one entry instead of duplicating per peer.
- Pick a sensible default download source automatically (free upload slot
  first, then shortest queue, then highest bitrate) rather than making the
  user always choose — tapping the row still opens a picker when more than
  one source exists.
- **Sort albums by relevance to the search query, then by popularity** —
  not alphabetically. Jorge's immediate follow-up feedback after trying
  the first version: alphabetical order buries what actually matches under
  whichever "Unknown artist" or unrelated folder happens to sort first
  among hundreds of peer responses. Relevance checks the artist, album,
  *and every song title* against the query (an exact artist/album match
  ranks highest; otherwise, the fraction of query words found anywhere in
  that text) — matching against song titles matters because a query is
  often a song name (`"one more time"`), not the album/artist name.
  Ties break on total peer count across the album (`sourceCount`), on the
  idea that a release many peers share is more likely a real, correctly
  matched result than a one-off.
- This is explicitly **best-effort, not exact**. Confirmed on a real
  search: a genuine result folder named `"lcd soundsystem (2005) lcd
  soundsystem"` (the artist name appearing on both sides of the year with
  no separator) can't be split into artist/album at all and falls back to
  "Unknown artist" — a real limitation of parsing folder names peers
  choose themselves, not a bug to chase down.

## Consequences
- Search results now read like a music library (grouped by album, with
  song titles) instead of a list of usernames — directly addressing the
  UX Jorge asked for.
- Real, messy Soulseek shares will sometimes land in "Unknown artist" or
  produce an album name that's really just a directory name someone
  picked. No attempt is made to fix this with an online metadata lookup
  (e.g. MusicBrainz) in this slice — revisit if it turns out to matter
  enough in practice once real usage happens.
- Unit-tested with both clean (`"Daft Punk - Discovery (2001)"`) and messy
  (no-separator) real-world-shaped paths — the messy case's exact
  (non-)parsing is asserted, not glossed over, so a future contributor
  sees the limitation in the test suite rather than being surprised by it.
