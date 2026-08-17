# 0019 — Fase 4, first slice: signed server-to-server trust

## Context
Fase 4 (federated friend-sharing) needs two self-hosted Musicat Server
nodes to trust and authenticate each other's requests before any real
feature (shared library, joint playlists) can be built on top. The plan
calls for "API server-a-server autenticada con las claves de nodo" and
"autorización por objeto en cada endpoint... y revocación real al deshacer
amistad" — this slice builds exactly that trust primitive, and nothing
more: no pairing UX (QR/codes), no shared-library/playlist logic, and NAT
traversal is explicitly deferred (see Consequences).

## Decision
- **`NodeIdentity.sign(bytes)`** (extends ADR 0015's Ed25519 keypair) signs
  arbitrary bytes with the node's own private key. `publicKeyBase64()`
  exposes the public key for others to verify against — now also returned
  from `GET /api/v1/node` alongside `nodeId`.
- **`Friend`** — a trusted remote node: `nodeId`, `publicKeyBase64`,
  `address` (where *this* node reaches them), optional `displayName`.
  Persisted via `FriendStore` to `<MUSICAT_DATA_DIR>/friends.json`.
- **Request signing scheme**: a node signs
  `'$method\n$path\n$timestamp\n$body'` (full request path, ISO-8601 UTC
  timestamp, raw body) with its private key, sent as `X-Node-Id`/
  `X-Timestamp`/`X-Signature` headers (`RequestSigner`). A verifier
  (`RequestVerifier`) looks up the claimed `nodeId` in its own
  `FriendStore`, rejects unknown nodes outright (**this is the
  object-level authz check** — a request is never trusted just because
  it's validly signed by *someone*, only if that someone is a
  specifically-trusted friend), rejects a timestamp more than 5 minutes
  off (bounds replay of a captured signature), then verifies the signature
  against that friend's stored public key.
- **`/api/v1/federation/*` routes**: `POST /friends` (register — see gap
  noted below), `GET /friends` (list), `DELETE /friends/<nodeId>`
  (revoke), and `GET /ping` — the only endpoint actually gated by
  `RequestVerifier`, existing solely to prove the trust model works before
  anything real is built on it.
- Binding the **full path** into the signed message (not just the
  Soulseek-route-style relative path) matters because shelf_router's
  `mount` only rewrites `request.url` for internal route matching —
  `request.requestedUri.path` (what verification uses) stays the original,
  full path regardless of mounting depth. A caller must sign the exact
  full path it's about to request.

## Consequences
- Tested with real `NodeIdentity`/`FriendStore` instances (temp
  directories, no fakes needed — there's no external dependency to fake
  here, unlike the slskd gateway) covering: valid signature accepted,
  unknown node rejected, tampered path rejected (signature no longer
  matches), stale timestamp rejected, and revocation making a previously
  valid signature fail immediately.
- **Verified for real across two actual running server processes**
  (not just the isolated router test): started two `bin/server.dart`
  instances, registered each as the other's friend via the real HTTP API,
  and used a real `RequestSigner` to send an actually-signed `GET
  /api/v1/federation/ping` from one to the other through the *full* mount
  chain — confirmed `200 {"pong": true}`, confirmed an unsigned request and
  one signed for a different path both get `401`, and confirmed that after
  revoking the friend, a freshly-signed request from that same node
  correctly gets `403 Unknown node`. This specifically validated the
  `requestedUri.path`-under-`mount` assumption above, which the isolated
  router test alone couldn't have caught (it never exercises a real mount).
- **Known, deliberate gap**: `POST /friends` has no protection at all yet
  — no pairing code, no local-only restriction, anyone who can reach a
  node's HTTP API can register themselves as a trusted friend today. This
  mirrors ADR 0016's own "no auth yet" note about `/api/v1/node` at the
  time, except this one is more serious since it grants real trust, not
  just an identity lookup. **This must be closed before any real
  shared-data endpoint is built** — likely via a short-lived pairing code
  exchanged out-of-band (QR/manual code), which is also where the actual
  pairing UX belongs. Left for a following slice, not decided here.
  **Closed the same day — see ADR 0020.**
- **NAT traversal is entirely out of scope for this slice.** Everything
  above was verified between processes that can already reach each other
  directly (localhost, or the same LAN) — nothing here helps two nodes on
  different home networks find or connect to each other. Per the plan's
  own risk list, that needs its own disposable spike before committing to
  a final design, separate from the trust primitive this slice establishes.
- No shared-library/playlist logic exists yet — this slice is purely the
  authentication layer those features will sit behind.
