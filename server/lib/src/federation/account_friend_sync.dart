import '../accounts/account_service_client.dart';
import '../accounts/account_session_store.dart';
import 'account_friend_devices.dart' show mergeFriendDevices;
import 'friend.dart';
import 'friend_store.dart';

/// Why a [FriendSyncService.sync] run ended the way it did.
enum FriendSyncStatus {
  /// This node isn't logged in to any account. Nothing was fetched, because
  /// there was nothing to fetch *as* — and, importantly, no network call was
  /// made at all.
  noSession,

  /// Skipped because another run was already in flight, or because the last
  /// one was more recent than [FriendSyncService.minSyncInterval].
  throttled,

  /// The account service didn't answer usably, so the local friend list was
  /// left exactly as it was.
  unreachable,

  /// The friend list was fetched and reconciled.
  completed,
}

/// What one [FriendSyncService.sync] run did.
///
/// Named constructors over a [FriendSyncStatus] rather than a bag of
/// booleans, so an impossible combination can't be constructed (there is no
/// such thing as a run that both had no session and added three friends) —
/// matching `LoginResult` and `RequestVerification`'s shape elsewhere in this
/// codebase.
class FriendSyncResult {
  const FriendSyncResult._(
    this.status, {
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
  });

  const FriendSyncResult.noSession() : this._(FriendSyncStatus.noSession);

  const FriendSyncResult.throttled() : this._(FriendSyncStatus.throttled);

  const FriendSyncResult.unreachable() : this._(FriendSyncStatus.unreachable);

  const FriendSyncResult.completed({
    required int added,
    required int updated,
    required int skipped,
  }) : this._(
         FriendSyncStatus.completed,
         added: added,
         updated: updated,
         skipped: skipped,
       );

  final FriendSyncStatus status;

  /// Whether this run got as far as calling the account service.
  bool get attempted =>
      status == FriendSyncStatus.unreachable ||
      status == FriendSyncStatus.completed;

  /// Whether the account service answered with a usable friend list.
  bool get fetched => status == FriendSyncStatus.completed;

  /// Friend accounts newly written to the local [FriendStore].
  final int added;

  /// Already-known account friends whose cached device set was refreshed.
  final int updated;

  /// Accepted friendships the account service listed that this node
  /// deliberately did **not** apply: a tombstoned account, a device-pinned
  /// friend, or an account whose devices are already pinned locally. Every
  /// one of these is a rule being enforced, not a failure — see
  /// [FriendSyncService].
  final int skipped;
}

/// Brings this node's local [FriendStore] into line with the friendships its
/// logged-in account has accepted on the account service — the bridge
/// between ADR 0048's friend requests and ADR 0049's local trust model,
/// which until now had nothing at all connecting them.
///
/// Sits alongside [FriendDeviceRefresher] (which refreshes the *devices* of
/// friends this node already has) and does the analogous job one level up:
/// which *accounts* are friends at all. It shares that class's discipline
/// deliberately — one fetch per run, an overlap guard, a minimum interval, a
/// failed fetch that changes nothing, and a tombstone check before anything
/// is written.
///
/// **Three rules constrain what this is allowed to do, and all three are
/// deliberate limitations rather than gaps to fill in later:**
///
/// 1. **Additive and updating only. It never removes a local friend.** If an
///    account this node knows locally is absent from the accepted list, the
///    local entry is left completely alone. A friend list is not a document
///    to be replicated: a partial response, a truncated one, a
///    misconfigured `accountServiceUrl` pointing at the wrong instance, or a
///    plain bug on the service must never be able to wipe someone's friends
///    — and unfriending stays a deliberate local act
///    (`DELETE /api/v1/federation/friends/<friendId>`), never something that
///    happens to a user because a server said so. The cost is that
///    *un*friending on the account service doesn't propagate here yet; that
///    is a known, stated limitation for a later round to close with an
///    explicit, confirmable action rather than a silent background deletion.
/// 2. **A tombstoned account is never added or updated** — checked here
///    before anything else, and again inside [FriendStore] under its own
///    lock, which is the check that actually holds under concurrency (see
///    [FriendStore.addFromAccountService]). This is the first sync path in
///    the codebase that could genuinely resurrect a removed friend, which is
///    exactly what tombstones were built for.
/// 3. **A legacy device-pinned friend is never touched**, in either
///    direction: they don't exist on the account service at all, their
///    single device *is* their identity, and their locally-learned address
///    is the only one anybody has for them.
///
/// Locally-learned reachability survives a sync: devices are merged with
/// [mergeFriendDevices], the same helper [FriendDeviceRefresher] uses, so
/// `address`/`udpCandidate` — which the account service does not record —
/// are carried over per nodeId rather than blanked, and a locally-learned
/// `relayUrl` wins over the account service's own.
///
/// **A friend learned here has no *address* for any device**, because the
/// account service stores keys and not addresses. What it does store is each
/// device's `relayUrl`, and that is what makes such a friend usable:
/// `reachFriend` routes `<relay http origin>/<nodeId>/<path>` (ADR 0033, the
/// mechanism proven across real networks in ADR 0035/0047), so two people who
/// become friends purely through the account service can browse and download
/// from each other without ever exchanging an address. ADR 0050 shipped
/// without this and said so plainly; round B closed it.
///
/// A friend whose devices report *no* relay either (nobody has one
/// configured) still can't be initiated to. They can always *verify* — their
/// signed requests to this node are accepted the moment they arrive — but
/// browsing them fails fast and cleanly with `FriendUnreachableException`
/// (`friend_reachability.dart` finds no candidates at all, so it throws
/// immediately rather than timing out), which the sharing routes turn into a
/// `502 {"error": "Friend unreachable: ..."}`.
class FriendSyncService {
  FriendSyncService({
    required this.friendStore,
    required this.sessionStore,
    required this.accountService,
    this.minSyncInterval = const Duration(seconds: 30),
  });

  final FriendStore friendStore;
  final AccountSessionStore sessionStore;
  final AccountServiceClient accountService;

  /// The shortest gap between two *unforced* syncs. This class owns no timer
  /// — a scheduled/pushed cadence is a later round's job — so this exists
  /// purely as a floor under whatever ends up driving it, the same way
  /// [FriendDeviceRefresher.refreshInterval] bounds that sweep. A caller
  /// that must not be throttled (a person pressing "log in") passes
  /// `force: true`.
  final Duration minSyncInterval;

  DateTime? _lastSyncAt;
  bool _running = false;

  /// Fetches this node's account's accepted friends and reconciles them into
  /// [friendStore], subject to the three rules in this class's doc comment.
  ///
  /// With no session this returns [FriendSyncResult.noSession] having made
  /// **no network call at all** — not a call that fails, not a call that is
  /// discarded: none. A node that never logs in must behave exactly as it
  /// did before accounts existed.
  ///
  /// [force] bypasses [minSyncInterval] (never the overlap guard, which
  /// protects the store from two interleaved reconciliations rather than the
  /// service from traffic).
  Future<FriendSyncResult> sync({bool force = false}) async {
    // Both guards are evaluated, and [_running] is *set*, before this method
    // reaches its first `await` — the body of an `async` function runs
    // synchronously up to that point, which is the only thing that makes the
    // overlap guard real. Checking `_running` and then awaiting anything
    // before setting it would let two callers sail past it together, which is
    // exactly the interleaving it exists to prevent (and how the first draft
    // of this method failed its own test).
    if (_running) return const FriendSyncResult.throttled();

    final lastSyncAt = _lastSyncAt;
    if (!force &&
        lastSyncAt != null &&
        DateTime.now().difference(lastSyncAt) < minSyncInterval) {
      return const FriendSyncResult.throttled();
    }

    _running = true;
    try {
      final session = await sessionStore.load();
      if (session == null) return const FriendSyncResult.noSession();

      // Stamped only once there is really something to sync, so a logged-out
      // node's cheap no-op never eats into the next real sync's window.
      _lastSyncAt = DateTime.now();
      return await _syncAs(session.accountId);
    } finally {
      _running = false;
    }
  }

  Future<FriendSyncResult> _syncAs(String myAccountId) async {
    final remoteFriends = await accountService.friendsOf(myAccountId);
    // `friendsOf` collapses every failure to null (see its doc comment): an
    // unreachable service, a 403, a malformed body. All of them mean the
    // same thing here — this run learned nothing, so it changes nothing.
    if (remoteFriends == null) return const FriendSyncResult.unreachable();

    var added = 0;
    var updated = 0;
    var skipped = 0;

    for (final remote in remoteFriends) {
      // Defensive: an account is not its own friend, and adopting yourself
      // as a friend would make this node trust its own key as a peer's.
      if (remote.accountId == myAccountId) {
        skipped++;
        continue;
      }

      // Rule 2, first pass. The authoritative check is inside FriendStore's
      // own lock; this one is here so a tombstoned account costs nothing
      // beyond the read, exactly as `FriendDeviceRefresher` does it.
      if (await friendStore.isRemoved(remote.accountId)) {
        skipped++;
        continue;
      }

      final local = await friendStore.findByAccountId(remote.accountId);
      if (local == null) {
        final created = await friendStore.addFromAccountService(
          Friend(
            accountId: remote.accountId,
            // No cached devices to merge from, but routed through the same
            // helper anyway so there is exactly one conversion from the
            // account service's `DeviceLink` to a local `FriendDevice`.
            devices: mergeFriendDevices(const <FriendDevice>[], remote.devices),
            // The account service's username is the only name this node has
            // for a friend it has never paired with. `localNickname` stays
            // untouched and unset — that is the user's own label.
            displayName: remote.username,
          ),
        );
        if (created == null) {
          skipped++;
        } else {
          added++;
        }
        continue;
      }

      // Rule 3: a device-pinned friend is out-of-band local trust. Nothing
      // the account service says may edit or replace it.
      if (local.isDevicePinned) {
        skipped++;
        continue;
      }

      final refreshed = await friendStore.updateDevices(
        remote.accountId,
        mergeFriendDevices(local.devices, remote.devices),
      );
      if (refreshed == null) {
        skipped++;
      } else {
        updated++;
      }
    }

    return FriendSyncResult.completed(
      added: added,
      updated: updated,
      skipped: skipped,
    );
  }
}
