/// A basic, in-memory, per-caller cap on how many **new accounts** one
/// source address may create per [window] -- the missing half of
/// [LoginRateLimiter], which counts only *failures* and is keyed by
/// username, so the signup branch of `POST /accounts/login/complete` was
/// never throttled by anything at all.
///
/// ## What it is defending
///
/// Creating an account costs the service ~200ms of Argon2id **inside
/// `AccountStore`'s global mutation lock** (see its doc comment: the lock is
/// held end to end on purpose, so nothing else logs in meanwhile), plus a
/// full rewrite of `accounts.json`. It costs the caller one Ed25519
/// signature over a nonce -- microseconds. That asymmetry is the whole
/// problem: a single client can serialize the login endpoint for everybody
/// and grow the account file without bound, and nothing about it looks like
/// an attack to a rate limiter that only counts wrong passwords.
///
/// ## What it does and does not stop
///
/// - **Stops** one host from creating accounts in a loop: past
///   [maxCreations] in [window] it is refused before the hash is even
///   started, so the marginal cost of the attempt drops back to a cheap
///   `429`.
/// - **Does not stop** an attacker with many source addresses. Nothing
///   in-memory and per-IP can; that is a stated limit, not an oversight, and
///   the same one ADR 0048 already accepted for [LoginRateLimiter]'s
///   username scope.
/// - **Deliberately no global concurrency bound around the hash.** There
///   already is one, and it is the problem rather than the mitigation:
///   `AccountStore._mutationLock` serializes every login. Capping
///   concurrency again would add nothing; capping *how many creations a
///   source may demand* is what was missing.
/// - **A reverse proxy that does not preserve the source address makes every
///   caller share one budget** (they all arrive as the proxy's own address),
///   which on a small self-hosted relay means at most [maxCreations] new
///   accounts an hour in total. `X-Forwarded-For` is deliberately not read:
///   trusting an unauthenticated header would hand the attacker a fresh
///   budget per request, which is strictly worse than the proxy case.
///
/// Only *successful* creations are recorded ([record] is called after the
/// fact), so the map is bounded by "accounts actually created in the last
/// [window]" -- a failed or refused attempt leaves no key behind, and a
/// login that isn't a creation never touches this at all.
class AccountCreationLimiter {
  AccountCreationLimiter({
    this.maxCreations = 10,
    this.window = const Duration(hours: 1),
  });

  /// How many accounts one caller may create per [window]. Ten is generous
  /// for a self-hosted service where the operator is also most of the users,
  /// and still bounds the attack to two seconds of hashing an hour per
  /// address.
  final int maxCreations;

  final Duration window;

  final Map<String, List<DateTime>> _creations = {};

  /// Whether [client] (a source address, or any stable key the caller can
  /// derive) may create another account right now. Pure: it never records
  /// anything, because whether a login turns out to be a creation is only
  /// known afterwards -- see [record].
  bool allows(String client) {
    _prune();
    return (_creations[client] ?? const []).length < maxCreations;
  }

  /// Records that [client] just created an account.
  void record(String client) {
    _prune();
    (_creations[client] ??= []).add(DateTime.now().toUtc());
  }

  /// Drops timestamps older than [window], and any key left with none --
  /// the same "prune on every call" bound `AccountFriendDeviceResolver`
  /// uses on its own negative cache, and what keeps this map to "addresses
  /// that created an account in the last [window]" rather than letting it
  /// grow for the process's lifetime.
  void _prune() {
    final now = DateTime.now().toUtc();
    _creations.removeWhere((_, timestamps) {
      timestamps.removeWhere(
        (createdAt) => now.difference(createdAt) >= window,
      );
      return timestamps.isEmpty;
    });
  }
}
