# 0055 — The relay gets a name and a certificate, and the app gets a default

## Context
ADR 0054 built the default-relay mechanism and deliberately shipped it
empty: the only relay this project had ever deployed (ADR 0035) was a bare
IPv4 on Jorge's home line, over plain `ws://`, with no DNS name. Baking
that into a public repo has three separate problems, and only one of them
is about secrecy:

- **It publishes his home address**, permanently, in git history.
- **It breaks every install at once** the day the ISP changes that IP,
  with no fix short of shipping a new build — the failure mode a default
  is supposed to prevent, not create.
- **No transport encryption.** Every request is signed, so nothing can be
  forged or altered; but anyone on the path sees who you talk to, which
  tracks you fetch, and — the part that actually matters — the password
  at sign-in.

Jorge asked what TLS was, and then asked for it to be set up.

## Decision
- **`musicat-relay.duckdns.org`**, pointed at the existing public IP. A
  name rather than an address is what makes the IP survivable: when it
  changes, DNS follows and installed copies keep working.
- **A systemd timer on the relay CT re-points that name every 5 minutes**
  (`duckdns.service`/`.timer`, token in a `0600` file). Without this the
  name is just a slower version of the same brittleness.
- **Caddy in front of the relay**, terminating TLS on 443 with a Let's
  Encrypt certificate it obtains and renews by itself, reverse-proxying
  to the relay on `localhost:8090`. Chosen because it needs about four
  lines of config and handles ACME, renewal, and WebSocket upgrades with
  no further attention.
- **Port 8090 stays open and unencrypted, deliberately.** Every device
  already paired against `ws://178.60.174.231:8090` keeps working;
  `wss://` is added alongside rather than cut over. Nothing is migrated
  until the app's new default has been proven.
- **`defaultRelayUrl` is now set** to `wss://musicat-relay.duckdns.org/connect`.
  Emptying it stays a supported state, so a fork can clear it or point it
  elsewhere with a one-line change.

## Consequences

### The deployed relay was stale for the third time
`grep -rl buildAccountRouter` on the CT returned nothing: the running
relay predated the *entire* account service. So every end-to-end test of
Fase 5's accounts — items 1 through 4, four ADRs' worth — had only ever
run against relays spawned locally by the test itself. Nothing in Fase 5
had ever touched the real deployment.

This has now happened at ADR 0035, ADR 0047 and here. It is not a
coincidence and it is not going to stop happening on its own: the relay is
deployed by `tar` + `scp`, so nothing ties the running binary to a commit,
and nothing reports the mismatch. **A future round should give the relay a
version endpoint and check it as part of any real-network test**, because
"I tested it end to end" has now been wrong three times for the same
reason.

Redeployed from `9fa3337`, preserving `data/usernames.json` and keeping a
timestamped backup. Verified afterwards, from outside the box: a valid
Let's Encrypt certificate; a real `startMusicatServer` node connecting
over `wss://` and answering through the tunnel (`401 Invalid signature`
from the *node*, i.e. the relay forwarded a request the node then
correctly refused); and an account created over `https://` — the first
account ever created on the real relay. The test account was deleted
afterwards.

### Setting up the proxy broke something we had just built
Behind a reverse proxy every request arrives from `127.0.0.1`, so ADR
0054's per-source account-creation limiter would have collapsed the whole
internet into one bucket — a cap of 10/hour *in total*. The limiter's own
doc comment refuses `X-Forwarded-For` on the grounds that trusting an
unauthenticated header is strictly worse, which is correct in general.
The narrow exception: honour it **only when the connection itself came
from loopback**, where nothing but a local process can have set it. Also
take the *last* value rather than the first, since anything to the left of
what the proxy appended came from the peer.

### A flaky test, found and fixed rather than tolerated
ADR 0054 recorded the suite as intermittently flaky and worth chasing. It
bit twice more in this session, so I chased it: reproducible at about one
run in six, always `account_update_poller_test`'s "stop() really stops
it", always leaving a stray `/friend-requests` call.

**It was the test racing the poller, not a product bug.** A poll pass makes
two calls; the test waited for the *first*, called `stop()`, and cleared
the log — so the second landed afterwards. `stop()` cancels the timer and
deliberately does not abort work in flight, because abandoning a
half-applied sync would be worse. The test asserted something stricter
than `stop()` promises. Fixed by letting the call log go quiet before
asserting that nothing *new* starts — quiescing rather than sleeping
longer, so it is deterministic instead of merely likelier to pass. 15
consecutive runs of that file clean, then three full-suite runs clean,
where before it failed roughly one in six.

My first attempt at that fix made it *worse* (6 failures in 12) because I
picked a completion signal that was already true before the poller ran.
Worth recording: the second diagnosis only stuck because I looked at the
actual failure output instead of assuming the first fix had worked.

### Verified
`dart format`/`dart analyze` clean, **597 server tests** across three
consecutive full runs, **320 app tests**. The app's tests point at a dead
`127.0.0.1:1` address rather than the real relay, so `flutter test` never
touches the deployment.

### Open
- The DuckDNS token was pasted into a chat transcript. It only permits
  updating that one DNS record, but it is rotatable from duckdns.org if
  Jorge wants it rotated.
- `wss://` and plain `ws://` on 8090 both work; nothing yet migrates
  existing installs off the unencrypted one, and nothing warns about it.
- Port 80 must stay forwarded for renewals (every ~60 days), not just for
  the initial issuance — closing it later would break TLS about two
  months afterwards, silently until it did.
- The relay has no version endpoint (see above).
