# 0047 — Real cross-network test of the complete Fase 4.6 stack

## Context
The culmination of Fase 4.6: paired this PC (home WiFi) with Jorge's
phone (genuinely on mobile data, WiFi off) using nothing but the
embedded server (ADR 0042/0043) and the username directory (ADR 0045),
over the relay (ADR 0046 finally made this possible for the embedded
case) — no Termux, no manual IP address anywhere. This is the real,
first-hand version of the exact scenario ADR 0040 could only test on a
shared LAN, and the exact scenario the whole Fase 4.6 arc was built
for.

## The actual test
1. Configured `MusicatServerConfig.relayUrl` on both devices to the
   deployed relay (`ws://178.60.174.231:8090/connect`), restarted both
   apps — both showed "Relay: connected" for the first time via the
   embedded path.
2. Claimed usernames on both (`jorgepc`, `jorgephone`).
3. Mutual pairing via "Add a friend by username" — phone redeemed the
   PC's code addressed by username (registers PC→trusts→phone),
   then the reverse (phone→trusts→PC) the same way. Both sides
   confirmed showing each other in their friend lists.
4. Shared a real track from one device, downloaded it successfully on
   the other — byte-correct, through the real production sharing path,
   the friend addressed entirely via the relay/username resolution, no
   direct IP ever entered anywhere in this whole test.

**Result: fully successful**, but only after finding and fixing two
real, previously-unknown-because-never-tested gaps along the way.

## Gap 1: the deployed relay was stale
The relay's `relay_hub.dart` on Jorge's Proxmox CT had zero references
to `directory/lookup` — it predated the entire username-directory
feature (ADR 0045) and its subsequent bug fixes (issues #8/#9). A
lookup request fell through to the old catch-all forwarding route
(`nodeId='directory'`, `path='lookup'`), returning the wrong error
("Target node is not connected to this relay") instead of ever reaching
real directory logic. Found by directly grepping the deployed file over
SSH, not guessed at.

**Fixed**: redeployed via the same tar+scp process as ADR 0035 (the CT's
code isn't git-tracked against the real repo, so `git log` on it isn't
trustworthy — verified the actual file content, not the git metadata),
`dart pub get`, `systemctl restart musicat-relay`. Confirmed the new
route works immediately after, and — genuinely good sign — the PC's
`RelayClient` auto-reconnected to the freshly restarted relay
automatically within the same test (ADR 0036 working exactly as
designed, on a live, deployed relay, not just in a test).

**Consequence**: a code change to `server/lib/src/relay/` (or anything
the relay depends on) needs an explicit redeploy to actually reach
Jorge's live relay — nothing currently automates or even reminds about
this. Worth a note in `docs/self-hosting.md` or a small deploy script
at some point, not fixed here.

## Gap 2: Android's background service doesn't pick up settings changes on a normal close/reopen
Setting a relay URL (or, separately, re-claiming a username after the
relay was redeployed) required a full **Settings → Apps → Musicat →
Force stop**, not just closing and reopening the app — a normal
close/reopen leaves the existing `flutter_background_service` instance
running untouched, since that's the entire point of a background
service surviving the app being "closed." `embeddedServerProvider`
only re-reads the persisted relay URL when a *fresh* `ProviderContainer`
is created at `bootstrap()`, which a plain app reopen after Android
merely backgrounding it does not trigger at all.

**Not fixed here** — worked around live via Force Stop, which is a real
but obscure step for an ordinary user. A cleaner fix would have the app
proactively tell the running service to restart (or reconfigure itself)
when a relevant setting changes, rather than requiring the OS-level
force-stop. Flagged for a decision, not fixed in this ADR.

A related, not fully explained symptom during the same test: after
changing the relay URL, the phone's own app briefly couldn't reach its
*own* local embedded server at all (`Connection refused` from the HTTP
client, not a relay error) until the same Force Stop was performed.
Consistent with the same root cause (stale background service instance
from before the setting change) but not independently isolated further.

## Consequences
- Fase 4.6's original goal — Jorge's very first message that started
  this whole arc, "vamos a probar a conectar dos dispositivos y enviar
  canciones," now specifically without Termux and without ever typing
  an IP — is achieved and verified for real, across genuinely different
  networks, not just a shared LAN.
- Both gaps found here are operational/UX, not correctness bugs in the
  code that was already tested — exactly the category of thing that
  only surfaces from actually running the real system end to end,
  which is why this test was worth doing even after every individual
  piece already had its own real verification.
- Open follow-ups, not committed to yet: keep the relay redeploy step
  in mind for any future relay-side change; decide whether to build a
  proactive service-restart-on-settings-change mechanism for Android,
  or just document the Force Stop step somewhere a real user would see
  it.
