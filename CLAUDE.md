# Working on Musicat

**Read `docs/architecture.md` first.** It explains the three moving parts,
the trust model, and the two hard rules. `docs/adr/` is a chronological
decision log — useful for "why is this like this", useless as an
introduction.

## The two hard rules

Both come from the project owner. They constrain design, and several
rounds of work exist only to protect them. Breaking either is a serious
regression, not a trade-off to weigh.

1. **Established friends work offline.** Two people already friends must
   browse and download each other's shared music with the relay *and* the
   account service unreachable. `FriendStore` and `request_signing.dart`
   therefore import nothing networked — the code answering "is this a
   friend, is the signature good" structurally cannot make a network call.
2. **Removing a friend is instant, local, and sticks.** Never waits on the
   network; no sync may undo it (`removed_friends.json` tombstones).
   Propagation to the other side is layered on top, never a precondition.
   **But an explicit user action is not a sync** — accepting a request from
   someone you removed clears the tombstone; a background refresh never
   does.

## Gates

```
cd server && dart format . && dart analyze && dart test --concurrency=1
cd app    && dart format . && flutter analyze && flutter test --concurrency=1
```

**`--concurrency=1` is not optional** — without it both runners silently
drop test files here, and you get a green run that tested less than you
think.

## Traps this repo has actually been bitten by

- **Load-mutate-save stores need the mutex.** `AccountStore._mutationLock`
  is the reference shape. The same read-modify-write race has shipped and
  been fixed three separate times.
- **`shelf_router` matches in registration order**, with no most-specific-
  first rule. Explicit routes go before catch-alls, and a mounted router
  must be verified against a *real* server — a unit test bypasses `mount()`.
- **Writing to a Riverpod provider from `build()`, `initState` or a
  go_router `redirect` throws.** Three production crashes so far. Use
  `Future.microtask`, or make the provider's `build()` do the work.
  Riverpod 3 also retries failed providers on a timer by default, which
  here becomes an invisible network poll — the account providers disable it
  deliberately.
- **A test guarding an absence must count calls, not measure time.** A test
  pointed at a *closed* port cannot tell "never called" from "called" (it
  refuses in ~14ms). Use a recording blackhole, assert zero, and add an
  inverse assertion so it cannot pass vacuously.
- **Exact-map assertions break on additive fields** and make a safe change
  look like a regression. Assert the field the test is about.
- **`nodeId` pairs from the wire must be checked against
  `nodeIdForPublicKey`.** Three routes accept such a pair; all three call
  that one function.
- This machine's `ls` has non-standard columns — `awk '{print $5}'` is not
  the size. Use `stat -c%s`.

## The relay

Deployed on the owner's Proxmox CT; see the project memory for SSH and
layout. **It has silently been running stale code three times**, once
invalidating four ADRs' worth of "verified end to end" claims at once.

So: before believing *any* real-network measurement,

```
cd server && dart run tool/check_relay_version.dart https://musicat-relay.duckdns.org
```

Exit `0` it matches, `1` it doesn't (or won't say), `2` unreachable. Deploy
with `git archive HEAD server` → scp → extract → `dart pub get` →
`systemctl restart`, preserving `data/`.

## How work goes here

- **Implement through `/dev-team`**, not direct edits — the owner asked for
  this explicitly.
- **Verify what subagents report.** Several findings have turned out
  pre-existing rather than regressions, or simply wrong. Re-run the gates
  yourself and read the diff before acting on a report.
- **Run adversarial review before committing**, not after. It has paid for
  itself every round.
- **Confirm a fix is load-bearing** by defeating it and checking that
  exactly the expected tests fail.
- **An ADR per slice**, in `docs/adr/`, written in the first person and
  stating trade-offs and known gaps plainly rather than selectively.
- **Ask before pushing.**
- Ask what a *user* can now do. Twice a slice has been fully green, fully
  tested, and completely unreachable by the product.

## Conventions

- All code, comments and docs in **English**; UI copy in English too.
- Doc comments explain *why* and name the trap being avoided. The density
  is deliberate. Comments that assert facts about *other files* go stale —
  prefer reasoning.
- Never put internal plumbing (node ids, relay URLs, ports, "account
  service") into user-facing copy.
