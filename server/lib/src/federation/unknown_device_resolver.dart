/// How `RequestVerifier` asks — and the *only* way it can ask — for a
/// nodeId it has never seen to be resolved against the account service.
///
/// This interface exists to keep the offline rule structurally enforceable
/// rather than merely documented: an already-logged-in device must be able
/// to verify an established friend's signed request, and serve them a
/// track, with the account service completely unreachable. So the hot path
/// (`RequestVerifier` + `FriendStore`) holds no HTTP client and its
/// libraries import no networking package at all; the one implementation
/// that does (`AccountFriendDeviceResolver`, `account_friend_devices.dart`)
/// is injected behind this one-method interface and is only ever reachable
/// from the cache-*miss* branch. A verifier constructed without one (the
/// default, and what `UdpPuncher` always uses) can therefore never make a
/// network call, whatever else changes around it.
abstract interface class UnknownDeviceResolver {
  /// Best-effort: find out whether [nodeId] is a device of a friend
  /// account this node already trusts, and if so refresh that account's
  /// cached device set so a retry can succeed.
  ///
  /// Returns whether anything was actually learned — `false` (never an
  /// exception) for "rate-limited", "not a device of any known friend",
  /// "that account was deliberately removed", or "the account service
  /// couldn't be reached". Implementations must rate-limit themselves:
  /// this is called for every rejected request, so a peer signing with a
  /// nodeId that will never validate must not turn into one account-service
  /// call per attempt.
  Future<bool> resolveUnknownDevice(String nodeId);
}
