# 0057 — The device list, and making it actually decidable

## Context
ADR 0056 closed a set of shipped-but-unreachable server capabilities, and
ended by noting that they were now reachable only from `curl` — "which is
exactly the trap this ADR is about closing, one level up". This is that
level: the UI for managing your devices, and for seeing and withdrawing
friend requests you sent.

The device list matters most. ADR 0048 called `DELETE
/accounts/<id>/devices/<nodeId>` *"the real recovery mechanism for a
lost/stolen device"* and shipped it with no way for a person to invoke it.
It stayed that way for eight ADRs.

## Decision
- **Devices** (`/account/devices`): every device on the account, the current
  one marked, and unlinking behind a confirmation that names the device and
  says the two things a person would otherwise assume wrongly — it stops
  being able to act as your account, and **it is not told**. Node ids never
  reach the screen.
- **Unlinking the device you are on** signs this node out, landing on the
  sign-in form with the friend list intact. The app reads `signedOut` from
  the response body rather than inferring it from the id it sent.
- **Outgoing requests**: shown under the incoming ones, withdrawable.
  Deliberately not worded like unfriending — you are not friends yet, so
  nothing is being removed.
- **`accountsAvailable`** replaces the configuration guess, so "this copy of
  Musicat has no relay" is now this device's own word rather than an
  inference. The old guess survives only for the window before the embedded
  server is up to be asked, so a cold start does not flash that message.

## Consequences — the screenshot is what caught the real problem
The round passed 359 tests and looked finished. Then I looked at the
screenshot of it running against a real relay, and the device list read:

```
Linux   This device · Added today      Unlink
Linux   Added today                    Unlink
```

Two identical rows. The header even explained that "when two look alike,
the date is what tells them apart" — and the dates were the same too.

For the one question this screen exists to answer — *which of these is the
phone I lost?* — that is useless. The feature would have shipped green,
reachable, and still unable to do its job. The implementing agent flagged
it as the highest-value gap in the contract, and was right.

So the account service now records **`lastLoginAt`** per device, stamped on
every login, and the row leads with it: *"Used just now"* versus *"Not used
for 6 months"*. That removes the "nothing changed, write nothing" shortcut
a previous round added to the re-login path — deliberately, since a
recency value only written when something *else* changed would be exactly
as useless as `linkedAt` already was. Logins are rare; one file write each
is not worth optimising against a list you cannot act on.

**It is disclosed only to the account itself.** `GET /<accountId>/devices`
is readable by every mutual friend, who need the device keys to verify your
signatures and emphatically do not need a per-device last-seen signal about
you. So `DeviceLink.toJson` takes `includeLastLogin`, defaulting to
**false**: a new wire surface omits it unless it deliberately asks. That
direction is chosen so the easy mistake is the harmless one — forgetting
the flag on a friend-facing route would leak, forgetting it on a storage
path merely loses a cosmetic field. A test asserts the key is *absent
entirely* from what a mutual friend receives, and I confirmed it is
load-bearing by removing the gate and watching exactly that test fail.

## Verification
- `dart format`/`dart analyze` clean; **659 server tests** (from 657) and
  **361 app tests** (from 320), all re-run by me.
- The agent verified the round against a real relay, two real nodes and the
  real Linux app, with an isolated `XDG_DATA_HOME` so Jorge's own app data
  was untouched — and reported, unprompted, that one capture had caught his
  Discord window when he switched workspaces, that it deleted it, and that
  every later capture checks the active window first. Recording that
  because self-reporting it is the behaviour I want.
- **The screenshots predate the `lastLoginAt` fix**, so they show the
  two-identical-rows problem rather than its solution. The widget test
  covers the fix precisely: two same-platform devices linked the same day,
  asserting "Used just now" and "Not used for 6 months" appear and "Added
  today" no longer leads.

## Still open, and reported by the round rather than hidden
- **A declined outgoing request disappears silently.** The sender can never
  learn that someone declined — the row just stops being pending, which is
  indistinguishable from a cancel or a stale list. Fixed for pending, still
  open for answered.
- **`409` on cancel does not say what the answer was**, so the app can only
  say "they had already answered", never the case that matters: "they
  accepted — you are friends now".
- No device renaming (there is no route, and who may set the name needs a
  decision), no "sign out everywhere".
- Pre-existing and untouched: `friend_detail_screen.dart` renders "Added 1
  months ago".
