# 0010 — SlskdSoulseekClient: polling design and error mapping

## Context
Fase 2 needs a concrete `SoulseekClient` (ADR 0004) talking to a
self-hosted `slskd` instance over REST. slskd has no OpenAPI spec published
outside a running instance, so the design here comes from reading
`slskd`'s own controller/model source directly
(`src/slskd/{Search,Transfers,Core}/...` at `slskd/slskd` on GitHub), not
just its docs — a couple of load-bearing details aren't obvious from the
docs alone:

1. **`POST /api/v0/searches` doesn't return until the search finishes** (or
   times out, ~15s by default) — `SearchesController.Post` awaits
   `Searches.StartAsync(...)` fully before responding. A naive
   "await the POST, then show results" implementation would block the UI
   for the full search duration with no incremental feedback.
2. However, `StartAsync` **creates and persists the search record before**
   doing any of that waiting ("we do this so the UI has some feedback to
   show to the user that we've gotten their request" — its own comment).
   A concurrent `GET /api/v0/searches/{id}` from a second connection reads
   that same persisted state, live, independent of whether the original
   POST has returned.
3. `GET /api/v0/transfers/downloads` returns a **nested** tree —
   `[{username, directories: [{directory, fileCount, files: [Transfer]}]}]`
   (see `TransfersController.GetDownloadsAsync` /
   `UserResponse`/`DirectoryResponse` DTOs) — not a flat list of transfers,
   despite `GET .../downloads/{username}/{id}` returning a bare `Transfer`.
4. `TransferStates` is a C# `[Flags]` enum, serialized as a comma-joined
   string of every set flag (e.g. `"Completed, Succeeded"`,
   `"Queued, Remotely"`), not a single value.
5. Error bodies are inconsistent by design: ASP.NET's automatic
   `ProblemDetails` is explicitly disabled
   (`SuppressMapClientErrors = true`), so most error responses are just the
   exception's `Message` serialized as a bare JSON string, except the
   batch-download endpoint's own structured `{batch, failures: [...]}`
   body on partial failure.

## Decision
- **Search**: `startSearch(query)` generates the search `id` client-side
  (a UUID) and fires the POST without awaiting its resolution, returning
  the id immediately. Callers poll `getSearch(id)` (a plain `GET
  ?includeResponses=true`) to observe live progress — this is the only way
  to get incremental results at all, since slskd has no SSE endpoint (only
  a SignalR hub, which a plain REST client can't consume). `startSearch`
  does call `isConnected()` first and throws
  `SoulseekNotConnectedException` synchronously if not logged in, rather
  than relying on the fire-and-forget POST's error to surface (it can't —
  nothing awaits it).
- **Downloads**: `getDownloads()` flattens slskd's nested
  username/directory/file tree into a single `List<SoulseekTransfer>` —
  the download-queue UI doesn't need the grouping, and flattening once in
  the client keeps every caller from repeating it.
- **Transfer state**: collapsed into a 5-value `SoulseekTransferState`
  enum (`queued`, `inProgress`, `succeeded`, `failed`, `cancelled`) by
  splitting the comma-joined flag string, mirroring slskd's own
  `TransferStateCategories` groupings. A bare `"Completed"` with neither a
  success nor failure flag — which slskd's own code calls out as
  "malfunction or regression" — is treated as `failed` rather than
  left in limbo.
- **Errors**: `enqueueDownload` explicitly accepts 200/201/207 as
  non-throwing (all carry a body worth inspecting) and only throws when
  either the whole batch failed (200 with every file in `failures`) or the
  HTTP call itself errored (404 → `SoulseekUserOfflineException`, anything
  else → `SoulseekClientException`). `cancelSearch` accepts both 200
  (stopped) and 304 (already finished) as success. Every other call uses a
  shared `_handle` wrapper that maps any `DioException` to
  `SoulseekClientException`, extracting the message whether the body is a
  bare JSON string or a `{message: ...}` object.
- **Not using the obsolete single-file download endpoint**
  (`POST /downloads/{username}`) — its own docs mark it for removal, and it
  has weaker error handling (offline peers fall through to a generic 500
  instead of the batch endpoint's dedicated 404).

## Consequences
- The interface stays honest about being poll-based (see the doc comments
  on `SoulseekClient` in ADR 0004's file) rather than pretending to be
  reactive — the Search screen's presentation layer will drive its own
  polling timer against `getSearch`/`getDownloads`, same pattern as the
  sleep timer's plain-Dart `Timer`.
- Unit-tested against mocked HTTP (`test/slskd_soulseek_client_test.dart`,
  using a hand-written `FakeHttpAdapter` rather than a mocking framework,
  consistent with `FakeAudioPlayerController`), and separately verified
  end-to-end against a real self-hosted `slskd` instance (Docker on a
  Debian 12 CT): a real search (`"daft punk one more time"`) showed the
  `inProgress` → `completed` transition live via polling while the
  initiating POST was presumably still blocked server-side, real search
  results parsed correctly (hundreds of peers, real filenames/sizes/
  bitrates), and a real download was enqueued, tracked through
  `inProgress` → `succeeded` with correct byte counts, and the file
  landed on disk exactly where expected. The blocking-POST/live-GET design
  (point 2 above) is therefore confirmed, not just inferred from source.
- slskd's license is AGPL-3.0-only with additional terms that only trigger
  on distributing a *modified* copy (see `FORKING.md`); talking to an
  unmodified, self-hosted instance purely over its REST API — as this
  phase does — doesn't trigger those terms. Revisit if a later phase
  (Musicat Server wrapping slskd) changes that relationship.
