/// A basic, in-memory, per-username failed-login lockout for `POST
/// /accounts/login/complete` -- tracks consecutive wrong-password attempts
/// and refuses further attempts for [lockoutDuration] once [maxAttempts] is
/// reached, until a lockout expires or a correct password resets the
/// counter. Deliberately simple (a fixed threshold and a fixed cooldown,
/// not a sliding window or exponential backoff) -- enough for a small
/// self-hosted service to not leave password-guessing completely
/// unthrottled, without the added complexity a larger deployment might
/// eventually want.
///
/// Scoped to username, not to the calling device/IP: this endpoint's
/// per-attempt cost is already high relative to a plain unauthenticated
/// guess (each attempt needs its own `login/start` round trip and a valid
/// Ed25519 signature over that exact nonce, see `login_nonce_store.dart`),
/// so the attacker-controlled variable worth throttling here is "how many
/// times has *this username* been guessed against recently", regardless of
/// which device/IP the guesses came from -- an attacker rotating source
/// IPs (trivial) shouldn't get a fresh budget of attempts against the same
/// account. A future round could add IP-scoped limiting on top of this if
/// it turns out to matter in practice (e.g. one caller spraying guesses
/// across many different usernames).
class LoginRateLimiter {
  LoginRateLimiter({
    this.maxAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 60),
  });

  final int maxAttempts;
  final Duration lockoutDuration;

  final Map<String, int> _consecutiveFailures = {};
  final Map<String, DateTime> _lockedUntil = {};

  /// Whether [username] is currently locked out. A lockout that has
  /// already expired is cleared as a side effect of checking it, so a
  /// caller never needs to separately "unlock" anything once time has
  /// passed.
  bool isLockedOut(String username) {
    final until = _lockedUntil[username];
    if (until == null) return false;
    if (DateTime.now().toUtc().isBefore(until)) return true;

    _lockedUntil.remove(username);
    _consecutiveFailures.remove(username);
    return false;
  }

  /// Records a failed `login/complete` attempt (wrong password) for
  /// [username]. Once [maxAttempts] consecutive failures accumulate, starts
  /// (or restarts) a [lockoutDuration] lockout -- a correct password
  /// during an active lockout still fails (see `account_routes.dart`,
  /// which checks [isLockedOut] before ever verifying the password) and
  /// does not reset or shorten it.
  void recordFailure(String username) {
    final failures = (_consecutiveFailures[username] ?? 0) + 1;
    _consecutiveFailures[username] = failures;
    if (failures >= maxAttempts) {
      _lockedUntil[username] = DateTime.now().toUtc().add(lockoutDuration);
    }
  }

  /// Resets [username]'s failure count after a successful login/signup --
  /// a genuine success is proof this wasn't an attacker blindly guessing,
  /// so there's no reason to keep counting past it.
  void recordSuccess(String username) {
    _consecutiveFailures.remove(username);
    _lockedUntil.remove(username);
  }
}
