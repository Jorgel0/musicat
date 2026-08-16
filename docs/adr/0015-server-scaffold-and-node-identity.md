# 0015 — Musicat Server scaffold and node identity

## Context
Fase 3 introduces `server/`: a self-hosted Dart backend that will wrap
`slskd` and, in Fase 4, let two self-hosted Musicat Server instances talk
directly to each other for federated friend-sharing. That federated trust
model needs each node to have a stable identity from day one — retrofitting
identity onto an already-federating server would force a breaking migration
for anyone already running one.

The project's own `README.md` already commits `server/` to AGPL-3.0 (vs.
MIT for `app/`), specifically so the federated backend can't be turned into
a closed-source hosted service without contributing improvements back.

## Decision
- Scaffolded with `dart create -t server-shelf server` (`shelf` +
  `shelf_router`), matching the plan's choice of `shelf` over `dart_frog`.
  Package renamed from the template's generic `server` to `musicat_server`.
- Added `server/LICENSE` with the verbatim AGPL-3.0 text (from
  `gnu.org/licenses/agpl-3.0.txt`), fulfilling what the root README already
  promised.
- **Node identity**: an Ed25519 keypair (`package:cryptography`), generated
  once and persisted as a base64-encoded 32-byte seed in
  `<MUSICAT_DATA_DIR>/node_identity.json`. `nodeId` is the hex-encoded
  SHA-256 fingerprint of the public key — a stable string other nodes can
  use to recognize this server once Fase 4 adds federation, without needing
  to see or compare the raw public key.
  - Ed25519 chosen over RSA: smaller keys/signatures, no parameter choices
    to get wrong, and it's what `package:cryptography` supports natively
    without extra native dependencies — relevant since Fase 4 will reuse
    this same keypair to *sign* server-to-server requests, not just to name
    the node.
  - Only the 32-byte seed is persisted (not a separately-derived public
    key) — `Ed25519.newKeyPairFromSeed` deterministically regenerates the
    same public key from it, so there's one value to keep safe rather than
    two that could drift out of sync.
  - `NodeIdentityStore.loadOrCreate()` creates `MUSICAT_DATA_DIR` if it
    doesn't exist yet and generates a fresh identity the first time there's
    no `node_identity.json` there — losing that file changes the node's
    identity, which is called out in `server/README.md`'s Docker section
    (mount `/app/data` as a volume).
- Exposed for now via a bare `GET /api/v1/node → {"nodeId": "..."}`, plus a
  trivial `GET / → {"status": "ok"}` health check. No slskd-wrapping or
  federation endpoints yet — this slice is only the scaffold + identity.

## Consequences
- Verified with `dart test` (identity persistence/uniqueness across data
  directories, plus the two HTTP endpoints via a real subprocess) and
  manually: ran the server twice against the same `MUSICAT_DATA_DIR`,
  confirmed `GET /api/v1/node` returned the identical `nodeId` both times,
  and confirmed the persisted `node_identity.json` only contains the seed.
- The keypair isn't used to sign anything yet — that's Fase 4's job once
  there's a second node to talk to. This slice only establishes that the
  identity exists and survives restarts.
- No authentication/authorization on `/api/v1/node` — it's not sensitive
  (a public key fingerprint is meant to be shared), but every endpoint
  added from here on must still get real object-level authz before it
  touches anything sensitive (library contents, friend data), per the
  project's standing hard rule.
