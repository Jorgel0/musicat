# Work in progress — stopped 2026-09-06 evening

Everything committed is pushed (`5988997`). The uncommitted changes in
`server/` below are **a backend-dev round that was stopped mid-task**, not
finished work. `dart analyze` was clean when it stopped, but the tests were
never run against it and nothing here has been reviewed.

## What the round was asked to do (4 items)

1. **`GET /version` on the relay** — because the deployed relay has been
   stale three times (ADR 0035, 0047, 0055), most recently predating the
   whole account service, which invalidated every "verified end to end"
   claim about Fase 5 items 1-4. Also a way to actually *check* it from a
   real-network test, since a version nobody checks solves nothing.
   *Appears done*: `lib/src/relay/build_info.dart`, `test/relay/build_info_test.dart`,
   `.gitattributes` (for `git archive`'s `$Format:%H$` substitution), `tool/`.
2. **Outgoing friend requests** — list and cancel. Today a sent request
   vanishes from the app's model of the world: you cannot tell "unanswered"
   from "I typo'd the username", and cannot withdraw it.
   *Appears done*: `friend_request*.dart` and their tests are modified.
3. **Device unlinking reachable from the app** — the route has existed since
   ADR 0048, which calls it "the real recovery mechanism for a lost/stolen
   device", with no node-side route and no UI, so nobody can invoke it.
   **This is where it was interrupted** — mid-way through adding a
   `deviceName` to the login route so the UI can tell devices apart.
4. **A capability signal on `GET /api/v1/account`** so the app can say
   "this build has no relay set" instead of "try again in a moment"
   (ADR 0053's open question). Unknown whether it got this far.

## How to resume

Read the diff and finish it, or `git checkout -- server/` and re-run the
round from scratch — the brief is recoverable from this session. Do not
assume any of it is correct: it was never tested and never reviewed.

Delete this file once the round lands.
