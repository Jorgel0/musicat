import 'dart:math';

/// Short-lived, single-use codes that gate joining as a friend
/// (`POST /friends`) — the out-of-band trust bootstrap the plan calls for
/// ("emparejamiento... fuera de banda"): only someone who's been given a
/// currently-valid code (e.g. via a QR code shown in person, or a link
/// shared some other trusted way) can actually pair, closing the gap ADR
/// 0019 flagged (friend registration previously had no protection at all).
class PairingCodeStore {
  PairingCodeStore({this.ttl = const Duration(minutes: 10)});

  final Duration ttl;
  final Random _random = Random.secure();
  final Map<String, DateTime> _expiryByCode = {};

  /// Generates a new code, valid until [ttl] from now.
  ///
  /// 24 random bytes, hex-encoded: sized for a QR code or copy-paste link
  /// (the plan's primary pairing UX), not for manual typing digit by digit.
  String generate() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    final code = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _expiryByCode[code] = DateTime.now().toUtc().add(ttl);
    return code;
  }

  /// Consumes [code] if it's currently valid, returning whether it was.
  /// Always removes it — single-use, so it can never be redeemed twice
  /// even if this call loses a race with another attempt.
  bool redeem(String code) {
    final expiresAt = _expiryByCode.remove(code);
    if (expiresAt == null) return false;
    return DateTime.now().toUtc().isBefore(expiresAt);
  }
}
