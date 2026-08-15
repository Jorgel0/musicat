# 0012 — Cover art for search results via iTunes Search API

## Context
Jorge asked for album/song cover art in the Search screen right after the
artist/album/song grouping (ADR 0011) shipped. slskd's search responses
carry no artwork at all — just filenames and sometimes bitrate/duration —
so this has to come from somewhere else entirely, keyed on the same
best-effort artist/album guess the grouping already produces.

## Decision
- Query Apple's public iTunes Search API
  (`https://itunes.apple.com/search?entity=album&term=<artist> <album>`)
  directly from the client. No API key, no account, and it's a common,
  widely-used pattern for exactly this (client-side "fetch me an album
  cover" lookups in small/hobby apps). Considered and rejected for this
  slice: MusicBrainz + Cover Art Archive (two calls instead of one, and
  MusicBrainz's own rate limit is stricter); Spotify/Last.fm (both need
  registering for an API key/secret, which is unnecessary friction for a
  personal project's search screen).
- Skip the lookup entirely when the filename parser (ADR 0011) fell back
  to `"Unknown artist"` — querying iTunes for that literal string would
  waste a call and risks a confidently-wrong cover more than it helps.
- Cache lookups per `(artist, album)` using Riverpod's own
  `FutureProvider.family` result caching — no separate cache/TTL logic
  written. The same album can appear once per song row on screen, and the
  API is informally rate-limited (~20 requests/minute per Apple), so
  avoiding repeat queries matters more than ever refreshing a result.
- Reuse the exact same provider call (same cache entry) for both the
  album header's larger thumbnail and every song row's smaller one,
  rather than a separate per-song lookup — there's no such thing as
  per-track artwork in this data source anyway.
- Fail soft everywhere: a network error, a missing `results` array, or an
  `Image.network` load failure all fall back to a plain album icon rather
  than an error state.
- Throttle to 3 lookups in flight at once (a small hand-rolled queue, not
  a new dependency), rather than letting every visible row fire its own
  request the moment results render — courtesy toward the rate limit
  above, not a fix for a connection problem (see below).

## A wrong turn worth recording
The first real-device test showed every single lookup failing. The
initial (wrong) diagnosis: this machine's DNS returns an IPv6 address for
`itunes.apple.com` with no actual IPv6 route (`ip -6 addr` shows nothing,
`ping6` fails) — a real, common misconfiguration — so a `connectionFactory`
override was added to force IPv4 resolution. That made the error message
change but not go away, which prompted a second wrong theory (a burst of
concurrent connections getting flagged by a firewall).

Isolating the exact same request in a standalone `dart run` script (not
the full app) settled it: a plain, unmodified `HttpClient` — including a
burst of 20 concurrent requests — succeeded every time with no
modification at all. The `connectionFactory` override itself was the bug:
handing `HttpClient` a manually-connected raw socket bypassed however it
normally threads the hostname through for TLS SNI, and Akamai's edge (SNI-
routed, like most CDNs) reset the connection rather than serving a
generic default. Removing the override fixed it outright; the concurrency
throttle was kept, but only as a legitimate rate-limit courtesy, not
because the burst itself was ever the problem.

The lesson that generalizes: **don't patch dart:io's HTTP internals to
route around a suspected network problem without first proving the
problem exists outside your own code.** A two-line standalone script
would have shown the plain client already worked, long before writing (or
half-debugging) a custom `connectionFactory`.

## Consequences
- A wrong artist/album guess (ADR 0011's known limitation) now also means
  a wrong or missing cover, not just a wrong text label — the same
  underlying tradeoff, just more visible.
- Adds a direct dependency on an unauthenticated third-party API with no
  SLA; if Apple changes or rate-limits this endpoint harder, covers
  degrade to icons rather than the screen breaking, but this is worth
  revisiting if it becomes unreliable in practice.
- Unit-tested with a fake HTTP adapter (upsizing `100x100` → `600x600`, no
  results, a 500 error, and the "Unknown artist" skip) and a fake
  `CoverArtClient` to confirm the Riverpod provider actually caches
  instead of re-querying.
