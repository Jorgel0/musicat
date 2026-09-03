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
class LoginNonceStore {
  LoginNonceStore({this.ttl = const Duration(seconds: 60)});

  final Duration ttl;
  final Random _random = Random.secure();
  final Map<String, _PendingNonce> _byUsername = {};

  /// Generates a fresh 24-byte nonce for [username], valid for [ttl] --
  /// replacing whatever nonce a previous, still-pending `login/start` call
  /// for the same username may have issued (only the most recent one is
  /// ever redeemable; an abandoned earlier attempt just silently stops
  /// being useful rather than staying valid forever).
  List<int> generate(String username) {
    final nonce = List<int>.generate(24, (_) => _random.nextInt(256));
    _byUsername[username] = _PendingNonce(
      nonce,
      DateTime.now().toUtc().add(ttl),
    );
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
