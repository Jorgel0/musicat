import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'friend.dart';

/// A deliberate local removal of a friend account, persisted to
/// `<dataDirectory>/removed_friends.json`.
///
/// Tombstones exist because [Friend.devices] is a *cache* of what the
/// account service says: without them, deleting a friend locally would be
/// silently undone by the next device-list refresh or friend sync ("I
/// removed them and they came back"). Every path that could ever *learn*
/// about a friend account from the account service must consult
/// [FriendStore.isRemoved] first; only an explicit local re-add
/// ([FriendStore.add], i.e. the user pairing/accepting again) clears one.
class FriendTombstone {
  const FriendTombstone({
    required this.accountId,
    required this.removedAt,
    this.deviceNodeIds = const [],
  });

  final String accountId;
  final DateTime removedAt;

  /// The nodeIds this account's devices had at the moment it was removed.
  ///
  /// Recorded purely so a request from one of them can be refused *without
  /// a network call*: [accountId] alone can only be matched after asking
  /// the account service which account an incoming nodeId belongs to, so
  /// without this a removed friend who keeps calling would cost one
  /// account-service lookup every time — draining the shared lookup budget
  /// that friends' genuinely new devices depend on. Empty for a tombstone
  /// written before this field existed, and for one written for an account
  /// that wasn't a friend here in the first place; both degrade to the
  /// accountId-only check, which is still correct, just chattier.
  final List<String> deviceNodeIds;

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'removedAt': removedAt.toIso8601String(),
    'deviceNodeIds': deviceNodeIds,
  };

  factory FriendTombstone.fromJson(Map<String, dynamic> json) =>
      FriendTombstone(
        accountId: json['accountId'] as String,
        removedAt: DateTime.parse(json['removedAt'] as String),
        deviceNodeIds: [
          for (final id
              in (json['deviceNodeIds'] as List<dynamic>? ?? const []))
            id as String,
        ],
      );
}

/// Persists the list of trusted [Friend] accounts to
/// `<dataDirectory>/friends.json`, and the accounts deliberately removed
/// from it to `<dataDirectory>/removed_friends.json` (see
/// [FriendTombstone]).
///
/// Purely local: every method here reads and writes only this node's own
/// disk. This is the whole hot path of "is this a friend, and which one" —
/// it has no network client of any kind, by design (the offline rule: two
/// established friends must be able to share music with the account
/// service completely unreachable). Learning about a friend's *new* device
/// lives in `account_friend_devices.dart` instead, and reaches this store
/// only through [updateDevices].
class FriendStore {
  FriendStore(this.dataDirectory);

  final Directory dataDirectory;

  /// Serializes every mutating call on *this* store instance ([add],
  /// [remove], [setLocalNickname] and [updateDevices]) so their
  /// load-mutate-save cycles can never interleave -- the same plain
  /// `Future`-chaining mutex `AccountStore._mutationLock` and
  /// `UsernameDirectoryStore._claimLock` already use, for the same reason
  /// (issue #8), and for the same scope: this only has to serialize
  /// concurrent async calls inside one running process, not coordinate
  /// several processes sharing one file.
  ///
  /// Here it is what makes **Rule 2 (unfriending sticks)** hold under
  /// concurrency. Every mutator reads the whole file, awaits, and writes
  /// the whole file back, so a [remove] landing inside [updateDevices]'
  /// read-to-write window used to be silently undone: the refresh wrote
  /// back the list it had loaded *before* the removal, restoring the
  /// friend -- device keys and all -- while the tombstone sat inertly in
  /// `removed_friends.json`, since nothing on the verification path
  /// consults tombstones. That friend's signed requests then verified
  /// again, permanently. Reproduced at ~9% of randomly-timed removes
  /// against a real device refresh.
  ///
  /// Pure reads ([loadAll], the `findBy*` lookups, [isRemoved],
  /// [loadTombstones]) deliberately stay *outside* the lock: they are the
  /// hot path of every incoming signed request, and making them queue
  /// behind a slow refresh would put a network-fed operation in front of
  /// the offline verification path this store exists to keep local.
  /// `catchError` on the chained link (not on what callers see) keeps a
  /// failed mutation from poisoning the lock forever.
  Future<void> _mutationLock = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() operation) {
    final previous = _mutationLock;
    final result = previous.then((_) => operation());
    _mutationLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  File get _file => File(p.join(dataDirectory.path, 'friends.json'));

  File get _tombstoneFile =>
      File(p.join(dataDirectory.path, 'removed_friends.json'));

  Future<List<Friend>> loadAll() async {
    final file = _file;
    if (!file.existsSync()) return [];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return [
      for (final entry in json) Friend.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<Friend?> findByAccountId(String accountId) async {
    for (final friend in await loadAll()) {
      if (friend.accountId == accountId) return friend;
    }
    return null;
  }

  /// The friend account that currently has [nodeId] as one of its devices —
  /// the fast path every incoming signed request goes through (see
  /// `RequestVerifier`), and the direct replacement for the old
  /// `findByNodeId`: for a legacy device-pinned friend it matches exactly
  /// the same single entry it always did.
  ///
  /// If two friends' cached device sets both contain [nodeId] (only
  /// possible while one of the two caches is stale — a device belongs to
  /// one account at a time), **a device-pinned entry wins over an
  /// account-based one**, and among equals the first entry in the file.
  ///
  /// That rule is a deliberate, documented precedence, not an accident of
  /// storage order: a device-pinned friend is trust the user established
  /// locally, explicitly and out-of-band (they redeemed a pairing code
  /// with that exact device), whereas an account-based entry's device set
  /// is a *cache* of what the account service claims. Local, explicit
  /// trust beats a remote claim. Before this rule, which account a device
  /// authenticated as depended on `friends.json` insertion order, so the
  /// same two entries written in the opposite order produced the opposite
  /// authorization outcome for an identical signed request.
  ///
  /// The overlap should be unreachable in practice: [add] supersedes any
  /// entry sharing a device nodeId, and [updateDevices] prunes the overlap
  /// out of other account-based friends whenever the account service says
  /// who a device really belongs to now. This makes the outcome
  /// deterministic if it ever arises another way.
  Future<Friend?> findByDeviceNodeId(String nodeId) async {
    Friend? accountMatch;
    for (final friend in await loadAll()) {
      if (friend.deviceFor(nodeId) == null) continue;
      if (friend.isDevicePinned) return friend;
      accountMatch ??= friend;
    }
    return accountMatch;
  }

  /// Resolves whichever id a *local* caller happens to hold for a friend:
  /// an [Friend.accountId] first, then any of their devices' nodeIds.
  ///
  /// This is what the app-facing routes (`/friends/<id>/...`) and the
  /// joint-playlist participant lookup use, so an id stored before Fase 5
  /// (always a device nodeId, which for a device-pinned friend *is* their
  /// accountId) keeps resolving unchanged. Never used to authorize an
  /// incoming federation request — that always goes through
  /// [findByDeviceNodeId] plus a signature check.
  Future<Friend?> findByAccountOrDeviceId(String id) async {
    final friends = await loadAll();
    for (final friend in friends) {
      if (friend.accountId == id) return friend;
    }
    for (final friend in friends) {
      if (friend.deviceFor(id) != null) return friend;
    }
    return null;
  }

  /// Adds [friend], **superseding** any existing entry that names the same
  /// [Friend.accountId] *or* that shares any of [Friend.devices]' nodeIds.
  ///
  /// This is the *explicit* local trust decision (redeeming a pairing code,
  /// accepting a friend request), so it also clears any [FriendTombstone]
  /// for that account: re-adding someone you previously removed has to
  /// work. Nothing else clears a tombstone.
  ///
  /// Superseding on a shared *device* nodeId, not just on the accountId,
  /// is what makes this refactor's headline migration path work: someone
  /// already stored as a legacy device-pinned friend who re-pairs claiming
  /// their new portable account is the same human on the same device, so
  /// they must end up as one entry, not two. Two entries for one device
  /// break in both directions — `GET /friends` lists the person twice, a
  /// track shared with their confirmed accountId is refused to their own
  /// correctly-signed request because [findByDeviceNodeId] resolved the
  /// *other* entry, and removing one of the two leaves the other still
  /// trusted (a Rule 2 violation).
  ///
  /// Note the deliberate asymmetry with [updateDevices], which leaves
  /// device-pinned entries strictly alone: this method is the user in
  /// front of the device saying "trust this", while [updateDevices] is fed
  /// by the account service, which has no business overriding trust the
  /// user established out-of-band.
  Future<void> add(Friend friend) => _locked(() => _addLocked(friend));

  Future<void> _addLocked(Friend friend) async {
    final friends = await loadAll();
    final incomingNodeIds = {
      for (final device in friend.devices) device.nodeId,
    };
    friends.removeWhere(
      (f) =>
          f.accountId == friend.accountId ||
          f.devices.any((device) => incomingNodeIds.contains(device.nodeId)),
    );
    friends.add(friend);
    // Tombstone first, friend list second: a crash between the two writes
    // must never leave a friend trusted while a tombstone still says they
    // were removed, which would be a trusted friend that every path
    // capable of *learning* anything about them refuses to touch. This
    // order fails to the clean "nothing happened" state instead.
    await _clearTombstone(friend.accountId);
    await _save(friends);
  }

  /// Revokes trust in a friend account, addressed by its accountId or by
  /// any of its devices' nodeIds — no-op if it wasn't a friend. Signed
  /// requests from any of its devices are rejected from the next lookup
  /// onward (see `RequestVerifier`).
  ///
  /// Instant and purely local: never waits on, or needs, the account
  /// service. Also writes a [FriendTombstone] so no later refresh/sync can
  /// resurrect the account — including for an [accountOrDeviceId] that
  /// isn't currently a friend at all, so "remove first, learn about them
  /// later" still sticks.
  Future<void> remove(String accountOrDeviceId) =>
      _locked(() => _removeLocked(accountOrDeviceId));

  Future<void> _removeLocked(String accountOrDeviceId) async {
    final friends = await loadAll();
    final index = _indexIn(friends, accountOrDeviceId);
    final accountId = index == -1
        ? accountOrDeviceId
        : friends[index].accountId;
    final removedDeviceNodeIds = index == -1
        ? const <String>[]
        : [for (final device in friends[index].devices) device.nodeId];
    friends.removeWhere((f) => f.accountId == accountId);
    // Tombstone first, friend list second. The tombstone is the *durable
    // record of intent*, and it is the only thing that makes a removal
    // permanent -- for an account that isn't currently a friend at all it
    // is the entire effect of this call. Writing the friend list first
    // would mean a crash in between silently discards that intent while
    // still looking successful, which is exactly the failure Rule 2
    // forbids; this order can only ever fail the other way, leaving a
    // still-listed friend the user can simply remove again.
    await _addTombstone(accountId, removedDeviceNodeIds);
    await _save(friends);
  }

  /// Updates just [Friend.localNickname] for the friend with the given
  /// accountId (or any of its devices' nodeIds), leaving every other field
  /// untouched. Purely local: this never touches anything sent to or
  /// received from the friend itself.
  ///
  /// Returns the updated [Friend], or `null` if [accountOrDeviceId] isn't a
  /// known friend (in which case nothing is saved).
  Future<Friend?> setLocalNickname(
    String accountOrDeviceId,
    String? nickname,
  ) => _locked(() => _setLocalNicknameLocked(accountOrDeviceId, nickname));

  Future<Friend?> _setLocalNicknameLocked(
    String accountOrDeviceId,
    String? nickname,
  ) async {
    final friends = await loadAll();
    final index = _indexIn(friends, accountOrDeviceId);
    if (index == -1) return null;

    final existing = friends[index];
    final updated = Friend(
      accountId: existing.accountId,
      devices: existing.devices,
      displayName: existing.displayName,
      localNickname: nickname,
      devicesRefreshedAt: existing.devicesRefreshedAt,
    );
    friends[index] = updated;
    await _save(friends);
    return updated;
  }

  /// Replaces the cached device set of the *already-known* friend account
  /// [accountId] — the only way anything learned from the account service
  /// enters this store.
  ///
  /// Deliberately narrow, and the enforcement point for both hard rules
  /// this refactor has to protect:
  /// - it never *creates* a friend (returns `null` for an unknown
  ///   accountId), so a refresh/sync can't befriend anyone;
  /// - it refuses outright if that account has a [FriendTombstone]
  ///   (returns `null`), so a deliberate local removal is never undone.
  ///
  /// Also prunes [devices]' nodeIds from every *other* account-based
  /// friend's cached set: the account service is authoritative about which
  /// account a device belongs to right now, so leaving the same device
  /// listed under two friends would make [findByDeviceNodeId] a coin flip
  /// between two accounts. Legacy device-pinned entries are left alone —
  /// their single device *is* their identity, and it was established
  /// out-of-band by the user, not by the account service.
  Future<Friend?> updateDevices(
    String accountId,
    List<FriendDevice> devices, {
    DateTime? refreshedAt,
  }) => _locked(
    () => _updateDevicesLocked(accountId, devices, refreshedAt: refreshedAt),
  );

  Future<Friend?> _updateDevicesLocked(
    String accountId,
    List<FriendDevice> devices, {
    DateTime? refreshedAt,
  }) async {
    if (await isRemoved(accountId)) return null;

    final friends = await loadAll();
    final index = friends.indexWhere((f) => f.accountId == accountId);
    if (index == -1) return null;

    final updated = friends[index].copyWith(
      devices: devices,
      devicesRefreshedAt: refreshedAt ?? DateTime.now().toUtc(),
    );
    friends[index] = updated;

    final claimed = {for (final device in devices) device.nodeId};
    for (var i = 0; i < friends.length; i++) {
      if (i == index) continue;
      final other = friends[i];
      if (other.isDevicePinned) continue;
      final kept = other.devices
          .where((device) => !claimed.contains(device.nodeId))
          .toList();
      if (kept.length != other.devices.length) {
        friends[i] = other.copyWith(devices: kept);
      }
    }

    await _save(friends);
    return updated;
  }

  Future<List<FriendTombstone>> loadTombstones() async {
    final file = _tombstoneFile;
    if (!file.existsSync()) return [];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return [
      for (final entry in json)
        FriendTombstone.fromJson(entry as Map<String, dynamic>),
    ];
  }

  /// Whether [accountId] was deliberately removed locally (see
  /// [FriendTombstone]).
  Future<bool> isRemoved(String accountId) async {
    for (final tombstone in await loadTombstones()) {
      if (tombstone.accountId == accountId) return true;
    }
    return false;
  }

  /// Whether [nodeId] was one of the devices of an account this node
  /// deliberately removed (see [FriendTombstone.deviceNodeIds]).
  ///
  /// Exists so an incoming request from a removed friend's known device can
  /// be refused from local disk alone — [isRemoved] can only be consulted
  /// once the nodeId has been resolved to an account, which costs the very
  /// network call this avoids.
  Future<bool> isRemovedDevice(String nodeId) async {
    for (final tombstone in await loadTombstones()) {
      if (tombstone.deviceNodeIds.contains(nodeId)) return true;
    }
    return false;
  }

  /// The index in [friends] of whichever entry [accountOrDeviceId] names --
  /// accountId first, then any device's nodeId -- or `-1`.
  int _indexIn(List<Friend> friends, String accountOrDeviceId) {
    for (var i = 0; i < friends.length; i++) {
      if (friends[i].accountId == accountOrDeviceId) return i;
    }
    for (var i = 0; i < friends.length; i++) {
      if (friends[i].deviceFor(accountOrDeviceId) != null) return i;
    }
    return -1;
  }

  // The two tombstone helpers below are deliberately *not* wrapped in
  // [_locked]: they are only ever called from inside an already-locked
  // mutation, and locking them again would deadlock on the very chain
  // their caller is holding (the same reason `AccountStore` factors its
  // `_xxxLocked` bodies out).
  Future<void> _addTombstone(
    String accountId,
    List<String> deviceNodeIds,
  ) async {
    final tombstones = await loadTombstones();
    // Carry forward device ids from a previous tombstone for the same
    // account: re-adding and re-removing someone must not narrow what a
    // later request can be refused on without a lookup.
    // Materialized before the removeWhere below: `where`/`expand` are lazy
    // views over `tombstones`, so leaving this as an iterable would read it
    // back *after* the matching entries had already been dropped, and
    // silently carry nothing forward.
    final previous = tombstones
        .where((t) => t.accountId == accountId)
        .expand((t) => t.deviceNodeIds)
        .toList();
    tombstones.removeWhere((t) => t.accountId == accountId);
    tombstones.add(
      FriendTombstone(
        accountId: accountId,
        removedAt: DateTime.now().toUtc(),
        deviceNodeIds: {...previous, ...deviceNodeIds}.toList(),
      ),
    );
    await _saveTombstones(tombstones);
  }

  Future<void> _clearTombstone(String accountId) async {
    final tombstones = await loadTombstones();
    if (!tombstones.any((t) => t.accountId == accountId)) return;
    tombstones.removeWhere((t) => t.accountId == accountId);
    await _saveTombstones(tombstones);
  }

  Future<void> _save(List<Friend> friends) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final friend in friends) friend.toJson()]),
    );
  }

  Future<void> _saveTombstones(List<FriendTombstone> tombstones) async {
    await dataDirectory.create(recursive: true);
    await _tombstoneFile.writeAsString(
      jsonEncode([for (final tombstone in tombstones) tombstone.toJson()]),
    );
  }
}
