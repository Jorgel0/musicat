# 0037 — Relay visibility in the app UI, and a crash fix found along the way

## Context
ADR 0033/0034 both flagged the same gap: the app has zero UI visibility
into the relay fallback mechanism — not whether a friend has one on
file, not whether this device's own server is using one. Server-side
`relayUrl` was already exchanged during pairing and exposed by both the
friends-list and `/api/v1/node` endpoints, and the app's own
`FederationFriend`/`MyNodeInfo` models already parsed it — nothing was
ever rendered. Built via `/dev-team` (a `frontend-dev` round; pure
client-side, no server changes needed since the data already flowed
end to end).

## Decision
- **New `myNodeInfoProvider`** (`musicat_server_config_controller.dart`):
  a `FutureProvider<MyNodeInfo?>` exposing this device's full node info
  (previously only `myNodeIdProvider` existed, discarding everything but
  the id). `myNodeIdProvider` now derives from it instead of calling
  `getMyNode()` a second time.
- **Friends list** (`_FriendsList`): a friend with a non-null `relayUrl`
  on file gets a small `Icons.cloud_queue` icon (tooltipped "Has a relay
  fallback registered") next to the existing remove button. No raw URL
  shown — not meaningful to a non-technical user, and the same reasoning
  ADR 0035 already applied to the `MUSICAT_RELAY_URL` env var internally.
  Friends without one get no extra UI (the common case stays uncluttered).
- **Friend detail screen**: the same signal, as a plain "Relay fallback
  available" line under the app bar, shown only when applicable.
- **Server config sheet**: a new read-only status row (`_RelayStatusRow`)
  showing whether *this device's own* server is currently connected to a
  relay — "Relay: connected" / "Relay: not connected", loading/error
  states handled via `AsyncValue.when`.
- Explicitly out of scope: no live "this request actually used the
  relay just now" indicator — that needs new backend state tracking that
  doesn't exist. This is "has a relay on file" / "is connected to one
  right now", both already-available data.

## A real crash bug found during verification (not caused by this change)
Writing a widget test for the friends-list indicator required actually
exercising `friendsControllerProvider` with a *configured* server for
the first time — every previous "real" verification of the federation
feature (ADR 0028 onward) went through throwaway scripts calling
`FederationClient` directly over HTTP, never through the actual
`FriendsController`/`FriendsScreen` widgets. That's how this survived
undetected across nine ADRs of "verified for real."

`FriendsController.build()` called `unawaited(_refresh(client))` for
its initial load. `_refresh`'s very first statement (`state =
state.copyWith(loading: true, error: null)`) runs synchronously — Dart
runs an `async` function body synchronously up to its first `await`,
and there's no `await` before that line. That write happens *during*
`build()`'s own execution, before Riverpod's `Notifier` framework has
finished initializing this provider's state slot from `build()`'s
return value — which throws `Bad state: Tried to read the state of an
uninitialized provider`. Because the throw happens inside an `async`
function's synchronous prefix, it doesn't propagate to the caller
directly; it's captured into the returned (and `unawaited`, thus never
observed) Future, and resurfaces later as an unhandled asynchronous
error. Net effect: **the instant a Musicat Server is configured and the
Friends screen is first built, this throws** — a real, live bug in the
one feature Fase 4 was built around, not a hypothetical.

**Verified concretely**: a `ProviderContainer` test overriding
`musicatServerConfigControllerProvider` with a configured server and
reading `friendsControllerProvider` reproduced the exact reported stack
trace. Reverting the fix and rerunning confirmed the same failure;
reapplying it confirmed the fix.

**Fix**: defer the initial call — `unawaited(Future.microtask(() =>
_refresh(client)))` instead of `unawaited(_refresh(client))` — so its
synchronous prefix runs after `build()` returns and the provider's state
is actually initialized. The polling `Timer.periodic` callback was
already safe (it only ever fires long after `build()` has returned) and
is unchanged. `DownloadsController`'s equivalent `_poll` doesn't have
this bug — its first statement is the `await` itself, no synchronous
`state =` write beforehand — confirming this is specific to `_refresh`'s
structure, not a systemic issue elsewhere.

## Consequences
- `dart analyze`/`flutter analyze` and `dart format`/`flutter test` all
  clean on the app side; test count 120 → 125 (2 new widget tests in
  `friends_screen_test.dart` for the relay indicator/status row, 2 new
  in a new `friends_controller_test.dart` — one directly reproducing and
  fixing the crash, one confirming the unconfigured case is unaffected).
- Live-run verification (`flutter run -d linux`) confirmed a clean
  launch with no crash on unrelated screens; navigating into the actual
  Friends screen with a real friend that has a `relayUrl` on file
  (visually confirming the new icons render as intended, not just
  passing in a widget test) is still open — this dev machine has no
  input-automation tool available to drive the live window
  non-interactively, and no server is configured on it. Worth a quick
  manual look next time a real friend pairing with a relay is at hand.
- The crash fix is a correctness fix to already-shipped Fase 4 code
  (ADR 0028), found as a side effect of finally writing a real
  Riverpod-level test for `FriendsController` rather than only
  script-driven HTTP checks — a gap in this project's own verification
  coverage (real server-side testing, never real client-widget testing
  for federation) worth keeping in mind for future Fase 4 UI work.
