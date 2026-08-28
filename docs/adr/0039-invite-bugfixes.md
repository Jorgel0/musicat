# 0039 — Fix three bugs from the invite-link QA pass

## Context
A `/dev-team` `bug-hunter` + `feedback-critic` pass on ADR 0038 (invite
links/QR) filed three real issues on GitHub. This fixes all three, via
another `frontend-dev` round.

## Decision
- **[#5](https://github.com/Jorgel0/musicat/issues/5) — cold-start deep
  link crash.** The exact same bug class as ADR 0037's fix, reintroduced
  one commit later via a different call site: `_handleDeepLink`
  (go_router's top-level `redirect`) wrote to `pendingInviteProvider`
  synchronously, which on a cold app start runs from
  `_RouterState.didChangeDependencies()` — still inside Flutter's initial
  build pass — tripping Riverpod's build-time-mutation guard and getting
  swallowed into go_router's generic error page, silently losing the
  invite. Fixed the same way as ADR 0037: `Future.microtask(...)` around
  both provider-write branches (success and the `InviteUriException`
  catch — bug-hunter's report was explicit that both are affected). The
  redirect target itself doesn't depend on the write having happened
  yet, so it's still returned synchronously.
  - **Closed the coverage gap this exposed**: none of ADR 0038's 34 tests
    touched `appRouter`/`_handleDeepLink` at all — they all set
    `pendingInviteProvider` directly. New `app/test/app_router_test.dart`
    exercises the *real* router via `tester.platformDispatcher.
    defaultRouteNameTestValue` set before the first pump, genuinely
    simulating a cold start (an app-lifetime router singleton can't
    reproduce more than one cold start per process, since it reads that
    value once at construction — a new `createAppRouter()` factory lets
    each test build its own instance while exercising identical wiring).
    Covers all three outcomes: friend invite, playlist invite, and a
    malformed link hitting the error branch. Confirmed each test fails
    against the pre-fix code and passes with it.
- **[#6](https://github.com/Jorgel0/musicat/issues/6) — parser contract
  violation.** `InviteUri.parseUri` is documented to throw only
  `InviteUriException`, but `uri.queryParameters`'s lazy UTF-8 decode
  throws a raw `FormatException` for malformed percent-encoding (e.g.
  `%e0%e0`) — syntactically valid to `Uri.parse` itself, so the earlier
  `FormatException` guard around that call didn't cover it. Fixed by
  guarding the `queryParameters` access itself and reusing the resulting
  map for every subsequent lookup.
- **[#7](https://github.com/Jorgel0/musicat/issues/7) — inconsistent
  clobber guard.** `_AddFriendSheet._applyInvite` unconditionally
  overwrote a user-typed display name with a scanned/pasted invite's
  name; the sibling joint-playlist sheet already guarded against this.
  Fixed by extracting the shared rule into `fillIfEmpty()`
  (`app/lib/core/invite/fill_if_empty.dart`) and having both sheets call
  it — this is the second time these two near-identical `_applyInvite`
  methods diverged on exactly this point, so it's shared now instead of
  duplicated a third time.

## Consequences
- `dart format`/`flutter analyze`/`flutter test` all clean; app test
  count 159 → 166 (3 in `app_router_test.dart`, 2 in `invite_uri_test.dart`,
  2 in `friends_screen_test.dart`).
- All three fixes reviewed directly (diff read line by line, not just
  the subagent's report) and re-verified by rerunning the full suite
  myself before committing.
- The `createAppRouter()`/`appRouter` split is a small, permanent
  addition to `app_router.dart` — worth knowing about for any future
  test that needs to simulate app startup behavior, not just deep links.
