import 'dart:math';

class _PendingNonce {
  _PendingNonce(this.nonce, this.expiresAt);

  final List<int> nonce;
  final DateTime expiresAt;
}

/// Short-lived, single-use nonces for the `POST /accounts/login/start` +
/// `POST /accounts/login/complete` device-linking handshake -- mirrors
/// `PairingCodeStore`'s own TTL/single-use pattern, but keyed by username
/// instead of by a generated code, since a `login/complete` call needs to
/// correlate back to whichever nonce a *previous* `login/start` call for
/// that exact username issued (there is no separate code to hand back and
/// forth; the username itself is the correlation key).
///
/// Deliberately in-memory-only, same as [PairingCodeStore]: a pending login
/// is expected to complete within [ttl], never to survive a server
/// restart.
///
/// **Bounded, in two ways, because every key here is attacker-controlled.**
/// `POST /accounts/login/start` is unauthenticated and does no validation
/// whatsoever on the username it is handed -- by design, so its shape and
/// timing leak nothing about which accounts exist (ADR 0048) -- so anyone
/// can put arbitrary strings in this map as fast as they can send requests.
/// Nothing swept it: an abandoned entry stayed for the life of the process.
/// Now every [generate] first drops what has expired, which holds the map to
/// "logins started in the last [ttl]", and [maxPending] caps even that. A
/// flood therefore costs bounded memory and, at worst, somebody's pending
/// nonce being evicted -- one retriable `401` telling them to call
/// `login/start` again -- rather than growing until the relay dies for
/// everyone.
class LoginNonceStore {
  LoginNonceStore({
    this.ttl = const Duration(seconds: 60),
    this.maxPending = 10000,
  });

  final Duration ttl;

  /// The hard ceiling on how many logins may be pending at once. Reached
  /// only under a flood -- 10,000 nonces is a few hundred kilobytes, and a
  /// real self-hosted service has single digits pending at any moment.
  final int maxPending;

  final Random _random = Random.secure();
  final Map<String, _PendingNonce> _byUsername = {};

  /// How many nonces are currently pending. Exposed for tests and
  /// diagnostics; nothing in the login flow reads it.
  int get pendingCount => _byUsername.length;

  /// Generates a fresh 24-byte nonce for [username], valid for [ttl] --
  /// replacing whatever nonce a previous, still-pending `login/start` call
  /// for the same username may have issued (only the most recent one is
  /// ever redeemable; an abandoned earlier attempt just silently stops
  /// being useful rather than staying valid forever).
  List<int> generate(String username) {
    final now = DateTime.now().toUtc();
    _byUsername.removeWhere((_, pending) => now.isAfter(pending.expiresAt));
    // Only reachable while more than [maxPending] logins are genuinely in
    // flight, i.e. under a flood. Evicting the nonce closest to expiring
    // sacrifices the attempt with the least life left in it.
    while (_byUsername.length >= maxPending &&
        !_byUsername.containsKey(username)) {
      final oldest = _byUsername.entries.reduce(
        (a, b) => a.value.expiresAt.isBefore(b.value.expiresAt) ? a : b,
      );
      _byUsername.remove(oldest.key);
    }
    final nonce = List<int>.generate(24, (_) => _random.nextInt(256));
    _byUsername[username] = _PendingNonce(nonce, now.add(ttl));
    return nonce;
  }

  /// Consumes the pending nonce for [username] if one exists and hasn't
  /// expired, returning it -- `null` otherwise. Always removes whatever was
  /// there, even on an expired hit: single-use, exactly like
  /// [PairingCodeStore.redeem], so a stale or already-consumed nonce can
  /// never be redeemed twice no matter how many `login/complete` calls race
  /// for it.
  List<int>? redeem(String username) {
    final pending = _byUsername.remove(username);
    if (pending == null) return null;
    if (DateTime.now().toUtc().isAfter(pending.expiresAt)) return null;
    return pending.nonce;
  }
}
