# 0056 — Closing the shipped-but-unreachable items

## Context
Four things had been sitting open across ADR 0048, 0053 and 0055. Three of
them shared a shape: **built, tested, and impossible for a user to reach.**
Jorge asked for them closed.

This round was interrupted mid-task when the machine was shut down, and its
partial work sat uncommitted for six days (`WIP-NOTES.md` recorded where it
stopped). On resuming, it turned out to be substantially complete: 657
tests passed after fixing two stale assertions, and every item was wired.

## Decision

### A version endpoint, and something that actually checks it
**The deployed relay has been silently stale three times** (ADR 0035, 0047,
0055). The last time it predated the entire account service, which
invalidated four ADRs' worth of "verified end to end" claims at once — every
one of those tests had only ever exercised relays the tests themselves
spawned.

`GET /version` on the relay reports the commit it was built from,
substituted by `git archive` via `export-subst` in `.gitattributes` — which
works with this project's exact tar-based deployment and needs no build
step. It degrades to an honest "unknown" in a git checkout rather than
printing a literal placeholder.

The endpoint alone would have solved nothing, so
`tool/check_relay_version.dart` is the operational half: point it at a
deployed relay and it exits `0` if that relay is running the commit you
mean, `1` if it is running something else *or will not say*, `2` if it
cannot be asked. Meant as the first line of any script that then measures
something against a real relay.

It proved itself immediately. Run against the live relay before this
deploy: *"has no /version endpoint at all, which means it predates this
check — so it is certainly not running b405db7."* Exit `1`. I verified the
whole exit-code contract by hand rather than trusting the doc comment.

### Outgoing friend requests
A sent request used to vanish from the app's model of the world: you could
not tell "they haven't answered" from "I typo'd the username", and could
not withdraw it. `GET /friend-requests` now returns `outgoing` alongside
`requests`, **additively** — the existing key keeps its exact meaning, and
an app ignoring the new one behaves as before. Both come from a single
upstream fetch, so the one `live`/`fetchedAt` pair describes both honestly;
two fetches would have let one list be stale while claiming otherwise.

`POST /friend-requests/<id>/cancel` withdraws one. Only the sender, only
while pending — once accepted it is a friendship, and ending one of those
is a different operation. It deliberately **writes no tombstone**: it is
the undo of a send, not a decision to remove anybody.

### Device unlinking, reachable at last
ADR 0048 called `DELETE /accounts/<id>/devices/<nodeId>` *"the real recovery
mechanism for a lost/stolen device"* and shipped it with no node-side route
and no UI, so nobody could invoke it. There are now `GET /devices` and
`DELETE /devices/<nodeId>` on the node.

Two decisions worth recording:

- **Devices needed a name.** The model had none, and "linked 3 days ago" is
  not enough to pick which phone to revoke. The node now reports its own
  platform label at login — the only thing it can honestly know about
  itself — rather than the server inventing one.
- **Unlinking the device you are on is allowed**, and signs that node out
  (`{"signedOut": true}`), clearing the session and cached requests but
  never the friend list. Refusing it is worse in both directions: it makes
  "remove this device from my account" impossible from the only device
  somebody owns — the phone they are about to sell — while allowing it
  *without* clearing the session would leave the node believing it acts for
  an account that no longer knows it, so every call would quietly `401`
  with nothing on screen to explain why.

Nothing tells the unlinked device. It finds out when its next sync fails,
which is an acceptable gap for a device you are revoking precisely because
you no longer control it.

### `accountsAvailable`
ADR 0053's open question: `GET /api/v1/account` answered `{"account": null}`
both when signed out and when the node has no account service at all, so the
app had to guess between "sign in" and "this build has no relay set". It now
carries a capability flag alongside, additively.

## Consequences
- Two pre-existing tests failed on resuming, both asserting the *whole*
  response map by equality and so broken by an additive field. Fixed by
  asserting the field each test is actually about. Worth noting as a
  pattern: exact-map assertions make additive changes look like
  regressions.
- Gates: format and analyze clean, **657 server tests** (from 597) and 320
  app tests, all re-run by me.
- The relay was redeployed from this commit and the version check then
  passed against it — the first time this project can *demonstrate* that
  what it measured against is what it meant to deploy.

### Still open
Account recovery (a forgotten password) remains the last real design
question in Fase 5, deliberately untouched: with no email or SMS the
standard answer is recovery codes issued at signup, and that deserves an
explicit decision rather than being slipped into a cleanup round. The app
UI for devices and outgoing requests is the natural next round — all of the
above is currently reachable only from `curl`, which is exactly the trap
this ADR is about closing, one level up.
