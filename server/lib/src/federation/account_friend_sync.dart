import '../accounts/account.dart';
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
    this.removed = 0,
    this.skipped = 0,
  });

  const FriendSyncResult.noSession() : this._(FriendSyncStatus.noSession);

  const FriendSyncResult.throttled() : this._(FriendSyncStatus.throttled);

  const FriendSyncResult.unreachable() : this._(FriendSyncStatus.unreachable);

  const FriendSyncResult.completed({
    required int added,
    required int updated,
    required int removed,
    required int skipped,
  }) : this._(
         FriendSyncStatus.completed,
         added: added,
         updated: updated,
         removed: removed,
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

  /// Account friends dropped because the authoritative list no longer
  /// contains them -- the other side unfriended this node. Never includes a
  /// device-pinned friend, and never leaves a [FriendTombstone] behind; see
  /// [FriendStore.removeFromAccountService].
  final int removed;

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
/// 1. **It removes an account friend the authoritative list no longer
///    contains — and only then.** This is the half that makes unfriending
///    bidirectional: when the other side revokes the friendship on the
///    account service (`DELETE /accounts/<me>/friends/<accountId>`), they
///    stop appearing here, and this node drops them, cached device keys and
///    all, so their signed requests stop verifying from the next lookup
///    onward. It is also the one thing in this class with real blast radius
///    — a bug here silently deletes somebody's friends — so it is fenced in
///    on four sides:
///    - **only on a genuinely successful fetch.** `friendsOf` collapses
///      unreachable, refused, and malformed into one `null`, and a `null`
///      changes nothing at all, exactly as before. A friend list is never
///      *partially* applied, so a truncated response is not a thing that can
///      reach this loop.
///    - **only friendships the account service itself established.** A
///      device-pinned friend does not exist there at all (rule 3 below), and
///      neither does an account-based friend the two of you set up
///      out-of-band with a pairing code while both logged in — that is a
///      real shape, not a hypothesis (ADR 0049), and it is absent from
///      `GET /<me>/friends` forever. Their absence therefore carries no
///      information, and deleting them would destroy trust the user
///      established by hand along with the only address anybody has for
///      them. [Friend.confirmedByAccountService] is the discriminator, and
///      both checks are made again inside
///      [FriendStore.removeFromAccountService]'s own lock.
///    - **no tombstone.** A tombstone is the record of *this user's* own
///      deliberate removal; the other side unfriending you is not that, and
///      writing one would make a later re-friend silently fail to take. That
///      asymmetry is the single most important thing about this path — see
///      [FriendStore.removeFromAccountService].
///    - **a wrong-but-successful answer is still damaging, and is not
///      guarded against.** An account service that answered `200 []` because
///      of a bug on its side would drop every account-based friend this node
///      has. They come back on the next correct sync (no tombstone), but
///      each friend's locally-learned `address`/`udpCandidate` and the
///      user's own `localNickname` do not — those live nowhere else. No
///      sanity threshold is applied on purpose: any rule that refused a
///      suspiciously large removal would also refuse the legitimate "I
///      removed everyone from my other device", and silently keeping friends
///      the user has actually unfriended is the worse failure of the two.
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
      removed: await _removeRevokedFriends(remoteFriends, myAccountId),
      skipped: skipped,
    );
  }

  /// Drops every account-based friend this node holds that [remoteFriends]
  /// — a list the account service really did answer with — does not mention.
  /// Returns how many were dropped.
  ///
  /// Runs after the add/update pass rather than before it, so a friend that
  /// is present in the list is refreshed by the loop above and never
  /// momentarily absent from `friends.json` in between; and reads the store
  /// fresh, so it diffs against what that pass actually wrote.
  ///
  /// Every exclusion here is a rule from this class's own doc comment, and
  /// each is enforced again inside [FriendStore.removeFromAccountService]'s
  /// own lock, which is the copy that holds under concurrency:
  /// a device-pinned friend is invisible to the account service (rule 3); a
  /// friend that service has never vouched for is invisible to it too, which
  /// is the case of two people who paired out-of-band while both logged in
  /// (see [Friend.confirmedByAccountService]); this node's own account is
  /// never a friend of itself; and a friend the list *does* contain is
  /// obviously not revoked.
  Future<int> _removeRevokedFriends(
    List<AccountFriend> remoteFriends,
    String myAccountId,
  ) async {
    final stillFriends = {for (final remote in remoteFriends) remote.accountId};
    var removed = 0;
    for (final local in await friendStore.loadAll()) {
      if (local.isDevicePinned) continue;
      if (!local.confirmedByAccountService) continue;
      if (local.accountId == myAccountId) continue;
      if (stillFriends.contains(local.accountId)) continue;
      // Deliberately *not* `friendStore.remove`: that is the user's own
      // deliberate unfriending and writes a tombstone, which here would
      // permanently block a later re-friend. See
      // [FriendStore.removeFromAccountService].
      if (await friendStore.removeFromAccountService(local.accountId)) {
        removed++;
      }
    }
    return removed;
  }
}
