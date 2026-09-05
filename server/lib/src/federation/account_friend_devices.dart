import 'dart:async';

import '../accounts/account.dart';
import '../accounts/account_service_client.dart';
import 'friend.dart';
import 'friend_store.dart';
import 'unknown_device_resolver.dart';

/// Rebuilds a friend account's cached device set from what the account
/// service now says, keeping whatever *reachability* this node already
/// learned locally.
///
/// The account service is authoritative about which keys currently speak
/// for an account (so a device it no longer lists is dropped — that's how
/// unlinking a stolen phone eventually propagates to friends). Reachability
/// is split, and the split is the whole subtlety of this function:
///
/// - **`address`/`udpCandidate` are local-only.** The account service does
///   not record them and never will (see [DeviceLink]): they are learned by
///   pairing with that specific device on a specific network, and they are
///   carried over from [cached] whenever the same nodeId is still listed, or
///   left `null` if this node never learned one.
/// - **`relayUrl` is recorded by the account service too** (as of round B of
///   Fase 5 — before it, this function's doc comment stated flatly that the
///   service records no reachability at all, which is no longer true), so it
///   has two possible sources. **The locally-learned one wins**, and the
///   authoritative one is the fallback for a device this node has no cached
///   relay for — which is every device of a friend it never paired with, and
///   exactly the case that used to leave such a friend with no way to be
///   reached at all (ADR 0050).
///
/// Preferring the local value is the deliberate half. A cached relay was
/// established by really pairing with that device (`POST
/// /api/v1/federation/friends` exchanges `relayUrl` directly between the two
/// nodes, with no third party in the middle), whereas the authoritative one
/// is a claim relayed through the account service. Both point at a relay
/// that still has to prove control of the target nodeId before it can
/// forward anything — a wrong relay can misroute or drop a request, never
/// read or forge one — so this is a robustness preference, not a trust
/// boundary: first-hand knowledge beats second-hand when there is a
/// disagreement, and second-hand is infinitely better than nothing.
///
/// A device this node *has* paired with, whose relay has since changed, is
/// therefore refreshed by re-pairing rather than by the account service. That
/// is a real (if narrow) staleness cost, accepted knowingly: the stale relay
/// simply answers `502` and reachability falls through to the next candidate
/// (`friend_reachability.dart` tries every direct address before any relay,
/// and bounds each relay attempt separately).
List<FriendDevice> mergeFriendDevices(
  List<FriendDevice> cached,
  List<DeviceLink> authoritative,
) {
  final byNodeId = {for (final device in cached) device.nodeId: device};
  return [
    for (final device in authoritative)
      FriendDevice(
        nodeId: device.nodeId,
        publicKeyBase64: device.publicKeyBase64,
        address: byNodeId[device.nodeId]?.address,
        udpCandidate: byNodeId[device.nodeId]?.udpCandidate,
        // `??` on the *whole* cached relay, so an explicitly-cleared local
        // relay (null) still falls back to the authoritative one rather than
        // staying null forever.
        relayUrl: byNodeId[device.nodeId]?.relayUrl ?? device.relayUrl,
        linkedAt: device.linkedAt,
      ),
  ];
}

/// Resolves an incoming nodeId that matched *no* known friend's cached
/// device set against the account service — the one and only reason a
/// normal request path ever touches the network (see
/// [UnknownDeviceResolver]).
///
/// Rate-limited on two axes, because this runs on rejected requests and a
/// peer can repeat one forever:
/// - **per nodeId** ([minLookupInterval], 60s by default): a nodeId that
///   was just looked up is refused locally, with no network call, however
///   often it comes back. This is the negative cache.
/// - **globally** ([maxLookupsPerWindow] per [lookupWindow], 10/minute by
///   default): a flood of *distinct* made-up nodeIds — which no per-nodeId
///   cache can absorb — can't be amplified into unbounded traffic against
///   the account service either.
///
/// Refuses outright, before any network call, for a device belonging to an
/// account with a [FriendTombstone] (and again by accountId once one is
/// known, which covers a device linked after the removal); and only ever
/// refreshes accounts that are *already* friends, so nothing here can
/// create a friendship.
class AccountFriendDeviceResolver implements UnknownDeviceResolver {
  AccountFriendDeviceResolver({
    required this.friendStore,
    required this.accountService,
    this.minLookupInterval = const Duration(seconds: 60),
    this.lookupWindow = const Duration(minutes: 1),
    this.maxLookupsPerWindow = 10,
  });

  final FriendStore friendStore;
  final AccountServiceClient accountService;

  /// How long a just-attempted nodeId is refused locally before it is
  /// allowed to cost another lookup. Configurable (rather than a bare
  /// constant) purely so tests don't have to wait out the real value —
  /// the same shape `RelayClient`'s reconnect backoff already uses.
  final Duration minLookupInterval;

  /// The window and cap for the global limit described above.
  final Duration lookupWindow;
  final int maxLookupsPerWindow;

  /// Last lookup attempt per unknown nodeId. Entries older than
  /// [minLookupInterval] no longer suppress anything and are pruned on
  /// every call, which is what bounds this map to "distinct nodeIds seen in
  /// the last [minLookupInterval]" rather than letting it grow forever.
  final Map<String, DateTime> _lastAttempt = {};

  final List<DateTime> _windowAttempts = [];

  @override
  Future<bool> resolveUnknownDevice(String nodeId) async {
    // Checked first, and before the rate limiter even sees this nodeId: a
    // device of an account this node deliberately removed must cost
    // nothing at all. Otherwise a removed friend that keeps calling would
    // buy one account-service lookup per request out of the shared budget
    // below -- the budget that exists so a *current* friend's newly linked
    // device can be learned about.
    if (await friendStore.isRemovedDevice(nodeId)) return false;

    if (!_allowLookup(nodeId)) return false;

    final accountId = await accountService.accountIdForDevice(nodeId);
    if (accountId == null) return false;

    // A deliberate local removal always wins over anything the account
    // service says -- checked before the (more expensive, authenticated)
    // device-list call, not just before writing.
    if (await friendStore.isRemoved(accountId)) return false;

    final friend = await friendStore.findByAccountId(accountId);
    // Not a friend at all, or a legacy device-pinned friend (whose single
    // device is its whole identity and is never refreshed against
    // anything) -- either way there is nothing to learn here.
    if (friend == null || friend.isDevicePinned) return false;

    final devices = await accountService.devicesOf(accountId);
    if (devices == null) return false;

    final updated = await friendStore.updateDevices(
      accountId,
      mergeFriendDevices(friend.devices, devices),
    );
    return updated?.deviceFor(nodeId) != null;
  }

  bool _allowLookup(String nodeId) {
    final now = DateTime.now();
    _lastAttempt.removeWhere(
      (_, attemptedAt) => now.difference(attemptedAt) >= minLookupInterval,
    );
    _windowAttempts.removeWhere(
      (attemptedAt) => now.difference(attemptedAt) >= lookupWindow,
    );

    if (_lastAttempt.containsKey(nodeId)) return false;
    if (_windowAttempts.length >= maxLookupsPerWindow) return false;

    _lastAttempt[nodeId] = now;
    _windowAttempts.add(now);
    return true;
  }
}

/// Refreshes every account-based friend's cached device set on an interval
/// — the *scheduled* half of keeping trust current, next to
/// [AccountFriendDeviceResolver]'s reactive half.
///
/// This is what makes revoking a device (unlinking a lost phone) eventually
/// propagate to the friends who had it cached: without it, a device dropped
/// from an account would stay valid on every friend's disk forever. The
/// window is bounded by [refreshInterval] and nothing else — push-based
/// invalidation is deliberately *not* built (the owner de-prioritized it
/// explicitly; the blast radius here is "can still download music your
/// friends already shared", no messages, no payments, no identity).
///
/// Never touches legacy device-pinned friends, never creates a friend, and
/// never resurrects a removed one (all three are enforced one level down,
/// in [FriendStore.updateDevices]). A failed fetch leaves the cached set
/// exactly as it was: an account service that's down must not cause false
/// rejections between two established friends.
class FriendDeviceRefresher {
  FriendDeviceRefresher({
    required this.friendStore,
    required this.accountService,
    this.refreshInterval = const Duration(minutes: 30),
  });

  final FriendStore friendStore;
  final AccountServiceClient accountService;

  /// How often [start] re-runs [refreshAll]. Default 30 minutes — the
  /// middle of the 15-60 minute band the design settled on: often enough
  /// that a revoked device stops being trusted by friends within about
  /// half an hour, rarely enough to be invisible on a phone's data plan.
  /// Configurable so tests can drive it deterministically instead of
  /// waiting on wall-clock time.
  final Duration refreshInterval;

  Timer? _timer;
  bool _running = false;

  bool get isRunning => _timer != null;

  /// Starts the periodic refresh (the first run happens one
  /// [refreshInterval] from now, not immediately — nothing at startup
  /// depends on it, and a cold start shouldn't fire a burst of requests at
  /// the account service). Calling this twice replaces the schedule.
  void start() {
    stop();
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refreshAll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Refreshes every account-based friend once. Returns how many friends'
  /// cached device sets were actually updated. Overlapping runs are
  /// skipped (returns 0) rather than queued.
  ///
  /// **Abandons the rest of the sweep the first time the account service
  /// looks unreachable.** Being down is a property of the service, not of
  /// one friend, so continuing would just pay
  /// [AccountServiceClient.timeout] again per remaining account friend —
  /// five seconds each, serially, on every sweep, forever, for a result
  /// already known. Nothing is lost by stopping: a failed fetch never
  /// changes the cache anyway, and the next scheduled sweep retries the
  /// whole list from the top. Deliberately not a backoff state machine —
  /// [refreshInterval] is already the retry cadence.
  Future<int> refreshAll() async {
    if (_running) return 0;
    _running = true;
    try {
      var refreshed = 0;
      for (final friend in await friendStore.loadAll()) {
        if (friend.isDevicePinned) continue;
        final outcome = await _refresh(friend.accountId);
        if (outcome == _RefreshOutcome.updated) refreshed++;
        if (outcome == _RefreshOutcome.serviceUnreachable) break;
      }
      return refreshed;
    } finally {
      _running = false;
    }
  }

  /// Refreshes one friend account's cached device set. Returns whether the
  /// local cache was actually updated — `false` for an unknown or removed
  /// account, a legacy device-pinned friend, or an unreachable account
  /// service.
  Future<bool> refresh(String accountId) async =>
      await _refresh(accountId) == _RefreshOutcome.updated;

  /// [refresh] with the one distinction [refreshAll] needs and a `bool`
  /// can't carry: "nothing to do here" versus "the service is down".
  Future<_RefreshOutcome> _refresh(String accountId) async {
    if (await friendStore.isRemoved(accountId)) {
      return _RefreshOutcome.skipped;
    }

    final friend = await friendStore.findByAccountId(accountId);
    if (friend == null || friend.isDevicePinned) {
      return _RefreshOutcome.skipped;
    }

    final devices = await accountService.devicesOf(accountId);
    // `devicesOf` collapses every failure mode to null (see its doc
    // comment), so this covers a refused connection, a timeout and a 5xx
    // alike — all of them reasons to stop the sweep rather than repeat it
    // per friend. A 404 for one account would be misread as the service
    // being down; that costs one skipped sweep, which the next one undoes.
    if (devices == null) return _RefreshOutcome.serviceUnreachable;

    final updated = await friendStore.updateDevices(
      accountId,
      mergeFriendDevices(friend.devices, devices),
    );
    return updated == null ? _RefreshOutcome.skipped : _RefreshOutcome.updated;
  }
}

/// Why one account's refresh did nothing — see [FriendDeviceRefresher._refresh].
enum _RefreshOutcome { updated, skipped, serviceUnreachable }
