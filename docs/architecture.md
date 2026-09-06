# Musicat — architecture overview

A music player that also lets you share music directly with friends,
without a company in the middle. This document is the map: what the moving
parts are, how they trust each other, and the rules any change has to
respect. It is deliberately *not* a history — `docs/adr/` holds the
reasoning behind individual decisions, in the order they were made, and is
too long to read as an introduction.

## Goals

- Single Flutter codebase for Android (primary target), Windows, and Linux.
- Local-first: downloaded music always works offline.
- Soulseek search and download.
- Friend-to-friend sharing that is **federated** — your music lives on your
  devices and goes straight to your friend's, not through anyone's servers.

## The moving parts

Three things exist. Understanding which one you are changing is most of
understanding the codebase.

### 1. The app (`app/`, MIT)

The Flutter client: player, library, playlists, search, downloads, friends.
On desktop and Android it also **starts a Musicat Server inside itself**
(`app/lib/core/embedded_server/`), so a normal user never installs or
configures a server — see ADR 0042/0043. On Android that server runs in a
foreground service, which is why the app shows a second persistent
notification while it is reachable.

### 2. Musicat Server (`server/`, AGPL-3.0)

The node. It owns this device's cryptographic identity, its friend list,
what it shares, and it speaks to other people's nodes. Usually embedded in
the app; it can also be self-hosted separately (Docker, a NAS, a VPS) by
anyone who wants that.

Its app-facing HTTP API is **loopback-only** by default (ADR 0044), because
the app and the server are on the same machine. Self-hosting elsewhere is
supported via an opt-in API key.

### 3. The relay + account service (`server/bin/relay.dart`, one process)

Two separate modules that happen to share a process and a port:

- **`RelayHub`** (`server/lib/src/relay/`) — a dumb pipe. Nodes behind NAT
  cannot accept incoming connections, so each one holds a single *outbound*
  WebSocket to the relay, and the relay forwards HTTP requests down it. It
  authenticates nodes but never inspects or vouches for what it carries:
  every authorization check happens at the endpoints exactly as if the
  request had arrived directly (ADR 0033).
- **The account service** (`server/lib/src/accounts/`) — portable accounts
  (username + password), the device list for each account, and friend
  requests. Kept as separate code and tests from the relay on purpose:
  passwords are a categorically more sensitive secret than anything the
  relay handles (ADR 0048).

They share a process only because friend-request push reuses the WebSocket
each device already holds open. The wire between them is one-directional
and one method wide (`DeviceNotifier`).

Anyone can run their own. **Accounts are per-relay**: two people on
different relays cannot befriend each other by username.

### And, separately: slskd

Soulseek itself is spoken by [slskd](https://github.com/slskd/slskd), a
third-party .NET service, behind the `SoulseekClient` interface. It is a
separate process and does not run on Android.

## The trust model

This is the part to understand before changing anything in `server/lib/src/`.

**A `nodeId` is self-certifying.** It is the lowercase hex SHA-256 of an
Ed25519 public key (`nodeIdForPublicKey`, `identity/node_identity.dart`).
Anyone holding the key can recompute the id; nobody can produce a key for
an id they do not own. Every place that accepts a `nodeId`/public-key pair
from the wire must check them against each other — there are three such
places and they all call that one function.

**An account is a set of devices.** A `Friend` is an `accountId` plus a
cached set of that account's device keys. A friend paired the old way, with
a pairing code, is the degenerate one-device case where `accountId ==
nodeId` — which is why introducing accounts needed no migration of anyone's
`friends.json` (ADR 0049).

**Requests are signed, not authenticated by transport.** An incoming
federation request carries `X-Node-Id`, `X-Timestamp` and `X-Signature`
over a canonical string. `RequestVerifier` resolves the nodeId to a friend
account from local disk and checks the signature. TLS and the relay are
about privacy and reachability, never about trust.

**Authorization is per object.** Being an authenticated friend is never
enough: each endpoint checks that *this* track or playlist was shared with
*that* account (ADR 0027).

## Two hard rules

Both come from the project owner, and both constrain design rather than
being nice-to-haves. Several rounds of work exist mainly to protect them.

**1. Established friends work offline.** Two people who are already friends
must be able to browse and download each other's shared music with the
relay *and* the account service completely unreachable — same WiFi, no
internet. So `FriendStore` and `request_signing.dart` import nothing
networked at all: the code that answers "is this a friend, and is the
signature good" structurally *cannot* make a network call. The one
exception is a cache miss on an unknown device, reached through a
one-method interface (`UnknownDeviceResolver`) so it is impossible to
widen by accident. `test/federation/offline_sharing_test.dart` guards this
by asserting **zero** requests reach a recording blackhole.

**2. Removing a friend is instant, local, and sticks.** It never waits on a
network call, and no later sync can undo it — `removed_friends.json` holds
a tombstone for that. Propagating the removal to the other side is layered
*on top* (a durable retry queue), never a precondition (ADR 0052).

A corollary worth knowing: an *explicit user action* is not a sync.
Accepting a friend request from someone you previously removed clears the
tombstone; a background refresh never does (ADR 0054).

## How a node reaches a friend

`federation/friend_reachability.dart`, in order:

1. **Every device's direct address**, most-recently-linked first. All of
   them, before any relay is tried — a device that answers in milliseconds
   must never sit behind another device's dead relay.
2. **Then the relays.** Bounded by their own, more generous timeout.

A friend added purely by username has no direct address at all (the account
service records keys, not addresses), so today they are reached only via
the relay. Local discovery over mDNS is the missing half of rule 1 for that
case, and is not built yet.

## Layout

### `app/`

Feature-first: each feature under `app/lib/features/` owns its `domain/`
(entities, repository interfaces, use cases), `data/` (implementations) and
`presentation/` (Riverpod providers, screens, widgets). This keeps a
feature's full vertical slice in one place, so a contributor can pick up one
feature without reading the rest.

Cross-cutting infrastructure lives in `app/lib/core/`:

- `core/audio/` — `AudioPlayerController`, the interface the app plays
  through; implemented over `just_audio` + `audio_service`.
- `core/database/` — the Drift schema: the source of truth for the local
  catalog, playlists and settings.
- `core/network/soulseek/` — the `SoulseekClient` interface, with an
  `slskd/` implementation. Abstracted so the backend can change without
  touching the player.
- `core/network/federation/` — clients for this device's *own* server.
- `core/embedded_server/` — starting that server in-process (desktop) or in
  a background isolate (Android).

### `server/lib/src/`

- `identity/` — this node's Ed25519 keypair and its nodeId.
- `federation/` — the friend list, request signing and verification,
  reachability, and the routes other people's nodes call.
- `sharing/` — shared tracks and joint playlists, and their object-level
  authorization.
- `accounts/` — the account service (and, on a node, the session saying
  which account this device acts for).
- `relay/` — the hub, the client each node runs, and the wire protocol.
- `nat/` — STUN and UDP hole-punching. Largely superseded by the relay: it
  works between some pairs of networks and not others (ADR 0032).
- `http/` — the loopback-only gate for app-facing routes.
- `soulseek/` — the slskd client.

## Conventions worth knowing before a first PR

- **Doc comments explain *why*, and name the trap being avoided.** The
  density is deliberate — much of this code encodes a decision that is not
  obvious from the code itself. A comment asserting a *fact about another
  file* is the kind that goes stale; prefer explaining the reasoning.
- **Load-mutate-save stores are serialized** by a `Future`-chaining mutex
  (`AccountStore._mutationLock` is the reference shape). A concurrent
  read-modify-write race here has been shipped and fixed three times.
- **`shelf_router` matches in registration order**, with no most-specific-
  first rule. Explicit routes must be registered before catch-alls, and
  mounted routers must be verified against a *real* server, not just called
  directly — a unit test bypasses `mount()`.
- **`flutter test` silently drops test files in this repo.** Always
  `flutter test --concurrency=1`. Same for `dart test`.
- **Writing to a Riverpod provider from `build()`, `initState` or a
  go_router `redirect` throws.** It has caused three separate production
  crashes here. Use `Future.microtask`, or make the provider's own `build()`
  do the work.
- When a test guards an *absence* ("we never call X"), assert it
  structurally — count the calls — and add an inverse assertion so it
  cannot pass vacuously. A test pointed at a closed port cannot tell "never
  called" from "called": that exact mistake hid a real bug (ADR 0049).

## Where the reasoning lives

`docs/adr/` — 55 records and counting, chronological. The ones that explain
the current shape rather than a passing decision:

| ADR | What it settles |
|---|---|
| 0015, 0019–0020 | Node identity; out-of-band pairing with codes |
| 0021–0024, 0032 | NAT traversal, and the real-world test where hole-punching failed |
| 0027 | Object-level authorization for shared tracks and playlists |
| 0033–0035 | The relay: design, automatic fallback, and a real cross-network test |
| 0042–0043 | The embedded server on desktop and Android |
| 0044 | App-facing routes are loopback-only |
| 0045 | Adding a friend by username, via a relay-hosted directory |
| 0048–0051 | Accounts: the service, account-based trust, friend requests |
| 0052 | Bidirectional unfriending, and the tombstone rules |
| 0055 | The relay's domain and TLS |
