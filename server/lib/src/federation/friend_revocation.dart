import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../accounts/account_service_client.dart';
import '../accounts/account_session_store.dart';

/// A revocation this node still owes the account service: "tell it I am no
/// longer friends with [friendAccountId]".
///
/// Exists because unfriending is **local and instant** (Rule 2, ADR 0049)
/// while propagating it is a network call that may well be impossible right
/// now -- on a plane, on a train, with the relay down. The local half has
/// already happened, permanently, by the time one of these is written; this
/// is the part that is still outstanding, and losing it would silently
/// downgrade the feature back to "removal is one-sided" for exactly the
/// users who were offline when they removed someone.
class PendingRevocation {
  const PendingRevocation({
    required this.friendAccountId,
    required this.asAccountId,
    required this.queuedAt,
    required this.attempts,
    required this.nextAttemptAt,
  });

  /// The friend account to un-friend on the account service.
  final String friendAccountId;

  /// Which account this node was logged in *as* when the user removed them.
  ///
  /// Recorded, rather than resolved at send time, because the session can
  /// change underneath a queued entry: `DELETE /accounts/<me>/friends/<x>`
  /// is authenticated as `<me>`, so a revocation queued as Alice is simply
  /// not something a node now logged in as Bob can send -- and sending it as
  /// Bob would be a request about *Bob's* friend list, which is a different
  /// (harmless, but wrong) thing entirely. [FriendRevocationService.drain]
  /// drops entries whose account is no longer this node's.
  final String asAccountId;

  /// When the user actually unfriended them -- the clock the age cap runs
  /// on. Never reset by a failed attempt: the bound is "how long we keep
  /// trying to deliver this", not "how long since we last tried".
  final DateTime queuedAt;

  /// How many delivery attempts have failed so far. Drives the backoff, and
  /// nothing else -- the give-up rule is [queuedAt]'s age, not this.
  final int attempts;

  /// The earliest moment [FriendRevocationService.drain] may try again. A
  /// freshly queued entry has this set to its [queuedAt], i.e. it is due
  /// immediately.
  final DateTime nextAttemptAt;

  PendingRevocation withFailure({required DateTime nextAttemptAt}) =>
      PendingRevocation(
        friendAccountId: friendAccountId,
        asAccountId: asAccountId,
        queuedAt: queuedAt,
        attempts: attempts + 1,
        nextAttemptAt: nextAttemptAt,
      );

  Map<String, Object?> toJson() => {
    'friendAccountId': friendAccountId,
    'asAccountId': asAccountId,
    'queuedAt': queuedAt.toIso8601String(),
    'attempts': attempts,
    'nextAttemptAt': nextAttemptAt.toIso8601String(),
  };

  factory PendingRevocation.fromJson(Map<String, dynamic> json) =>
      PendingRevocation(
        friendAccountId: json['friendAccountId'] as String,
        asAccountId: json['asAccountId'] as String,
        queuedAt: DateTime.parse(json['queuedAt'] as String),
        attempts: json['attempts'] as int? ?? 0,
        nextAttemptAt: json['nextAttemptAt'] == null
            ? DateTime.parse(json['queuedAt'] as String)
            : DateTime.parse(json['nextAttemptAt'] as String),
      );
}

/// Persists outstanding [PendingRevocation]s to
/// `<dataDirectory>/pending_revocations.json` -- the same
/// load-mutate-save-the-whole-file pattern, and the same plain
/// `Future`-chaining mutation lock, as `FriendStore`/`AccountStore`/
/// `AccountSessionStore` (see [FriendStore]'s own doc comment on that lock,
/// and issue #8).
///
/// Purely local disk: this class holds no HTTP client. Delivering what it
/// holds is [FriendRevocationService]'s job, and keeping the two apart is
/// what lets `DELETE /api/v1/federation/friends/<id>` durably record the
/// intent without anything networked being reachable from that path at all.
///
/// [FriendStore]: friend_store.dart
class PendingRevocationStore {
  PendingRevocationStore(this.dataDirectory);

  final Directory dataDirectory;

  Future<void> _mutationLock = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() operation) {
    final previous = _mutationLock;
    final result = previous.then((_) => operation());
    _mutationLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  File get _file =>
      File(p.join(dataDirectory.path, 'pending_revocations.json'));

  /// Everything still owed, in the order it was queued.
  ///
  /// Treats an unreadable or corrupt file as an empty queue rather than
  /// throwing: this is consulted from the removal path and from a background
  /// poll, and neither has anywhere useful to report a parse error to. The
  /// cost of that choice is losing outstanding revocations, which is exactly
  /// what an unreadable file has already cost.
  Future<List<PendingRevocation>> loadAll() async {
    final file = _file;
    if (!file.existsSync()) return [];
    try {
      final json = jsonDecode(await file.readAsString()) as List<dynamic>;
      return [
        for (final entry in json)
          PendingRevocation.fromJson(entry as Map<String, dynamic>),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<PendingRevocation> pending) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final entry in pending) entry.toJson()]),
    );
  }

  /// Records that [friendAccountId] must be un-friended on the account
  /// service, as [asAccountId], and returns the stored entry.
  ///
  /// Replaces any entry already queued for the same pair rather than adding
  /// a second: the queue is a *set* of outstanding facts ("I am not friends
  /// with X any more"), not a log of button presses, and delivering the same
  /// fact twice would be pure waste against an idempotent route. Replacing
  /// (rather than leaving the existing entry alone) resets the backoff,
  /// which is what a user removing someone again plainly means.
  Future<PendingRevocation> enqueue({
    required String friendAccountId,
    required String asAccountId,
    DateTime? queuedAt,
  }) => _locked(() async {
    final now = queuedAt ?? DateTime.now().toUtc();
    final pending = await loadAll();
    pending.removeWhere(
      (entry) =>
          entry.friendAccountId == friendAccountId &&
          entry.asAccountId == asAccountId,
    );
    final entry = PendingRevocation(
      friendAccountId: friendAccountId,
      asAccountId: asAccountId,
      queuedAt: now,
      attempts: 0,
      nextAttemptAt: now,
    );
    pending.add(entry);
    await _save(pending);
    return entry;
  });

  /// Drops the entry for [friendAccountId]/[asAccountId] -- delivered,
  /// definitively refused, or expired. No-op if it isn't there.
  Future<void> dequeue({
    required String friendAccountId,
    required String asAccountId,
  }) => _locked(() async {
    final pending = await loadAll();
    final before = pending.length;
    pending.removeWhere(
      (entry) =>
          entry.friendAccountId == friendAccountId &&
          entry.asAccountId == asAccountId,
    );
    if (pending.length != before) await _save(pending);
  });

  /// Records one failed delivery attempt for [friendAccountId]/[asAccountId]
  /// and when it may next be retried. No-op if the entry is gone (a
  /// concurrent [dequeue] wins, which is the safe direction: nothing is
  /// resurrected).
  Future<void> recordFailure({
    required String friendAccountId,
    required String asAccountId,
    required DateTime nextAttemptAt,
  }) => _locked(() async {
    final pending = await loadAll();
    final index = pending.indexWhere(
      (entry) =>
          entry.friendAccountId == friendAccountId &&
          entry.asAccountId == asAccountId,
    );
    if (index == -1) return;
    pending[index] = pending[index].withFailure(nextAttemptAt: nextAttemptAt);
    await _save(pending);
  });
}

/// Propagates a local unfriending to the account service, eventually and
/// without ever being in the way.
///
/// ## The rule this class exists to *not* break
///
/// `DELETE /api/v1/federation/friends/<id>` is instant, local and permanent.
/// It must keep returning immediately, keep working with the account service
/// completely unreachable, and keep taking effect the moment it returns.
/// Propagation is a guarantee layered *on top* of that, never a
/// precondition. So the removal path calls [revoke], which does two small
/// local-disk operations (read the session, append to
/// [PendingRevocationStore]) and then hands the actual network call off
/// unawaited. Nothing here can delay, fail, or change the removal.
///
/// The write is what makes the promise durable, and it is why the queue is a
/// file rather than a list in memory: "I unfriended someone on a plane"
/// has to still propagate when the plane lands, including across the app
/// being killed in between. Delivery is at-least-once, which the account
/// service's idempotent `DELETE /accounts/<me>/friends/<accountId>` makes
/// free -- so a crash after a successful send costs one redundant `204`,
/// never a lost revocation.
///
/// ## Bounded, in two different ways
///
/// - **Backoff** ([initialRetryDelay], doubling per failure, capped at
///   [maxRetryDelay]) bounds how *often* a dead account service is retried.
///   Without it a queue of five entries would cost five
///   [AccountServiceClient.timeout]s on every single poll, forever.
/// - **Age** ([maxAge]) bounds how *long* an undeliverable entry is kept, and
///   is deliberately an age rather than an attempt count. An attempt count
///   punishes exactly the user this feature is for: a phone that spends a
///   week off gets no attempts and would keep its entries either way, while
///   a phone with flaky signal burns through a count in an afternoon and
///   loses the revocation. Age says the same thing to both of them.
///
/// A dropped entry costs the *propagation* only -- the local removal and its
/// tombstone are already permanent and untouched, which is the pre-existing
/// behaviour this whole mechanism improves on.
///
/// ## It can never resurrect anything
///
/// This class only ever *sends* revocations. It never reads or writes
/// `FriendStore`, never adds a friend, and never un-tombstones one. The
/// worst a corrupt or replayed queue achieves is telling the account service
/// again about a friendship that is already over.
class FriendRevocationService {
  FriendRevocationService({
    required this.sessionStore,
    required this.accountService,
    required this.store,
    this.initialRetryDelay = const Duration(minutes: 1),
    this.maxRetryDelay = const Duration(hours: 6),
    this.maxAge = const Duration(days: 30),
  });

  final AccountSessionStore sessionStore;
  final AccountServiceClient accountService;
  final PendingRevocationStore store;

  /// The wait after the first failed attempt; doubles per further failure,
  /// capped at [maxRetryDelay]. Configurable (rather than a bare constant)
  /// so tests drive it deterministically instead of waiting on wall-clock
  /// time -- the same shape [FriendDeviceRefresher.refreshInterval] and
  /// `RelayClient.initialReconnectDelay` already use.
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;

  /// How long an undeliverable revocation is kept before it is given up on.
  /// See this class's doc comment for why this is an age and not a count.
  final Duration maxAge;

  bool _draining = false;

  /// Records that the local user has unfriended [friendAccountId], and
  /// kicks off a best-effort delivery attempt that this method does **not**
  /// wait for.
  ///
  /// Returns once the intent is durably on disk -- microseconds, no socket.
  /// Callers must have already done the local removal: this is the second
  /// half of an unfriending, never the first.
  ///
  /// With **no session** this does nothing at all: no queue entry, no
  /// network call, no error. A node that isn't logged in has no account
  /// friendships to revoke, so there is nothing to propagate and nothing to
  /// remember -- and the queue must not grow on a node that will never be
  /// able to drain it.
  Future<void> revoke(String friendAccountId) async {
    final session = await sessionStore.load();
    if (session == null) return;

    await store.enqueue(
      friendAccountId: friendAccountId,
      asAccountId: session.accountId,
    );
    // Deliberately not awaited, and deliberately the *whole* drain rather
    // than a single send: the entry is already durable, so from here on this
    // is indistinguishable from the background poll doing it, and the
    // removal route must not wait on a socket. `drain` swallows everything.
    unawaited(drain());
  }

  /// Delivers whatever is currently due, and returns how many revocations
  /// this run got rid of -- delivered, definitively refused, expired, or
  /// queued as an account this node is no longer logged in as.
  ///
  /// Called on every [AccountUpdatePoller] tick and immediately after each
  /// [revoke]. Overlapping runs are skipped rather than queued, exactly like
  /// [FriendSyncService.sync] and [FriendDeviceRefresher.refreshAll] -- two
  /// concurrent drains would send the same revocation twice for no gain.
  ///
  /// **Never throws.** Every caller is either a timer or an `unawaited`
  /// call, so an exception escaping here would be an unhandled async error
  /// with nobody to report it to.
  ///
  /// [AccountUpdatePoller]: account_update_poller.dart
  /// [FriendSyncService]: account_friend_sync.dart
  /// [FriendDeviceRefresher]: account_friend_devices.dart
  Future<int> drain() async {
    if (_draining) return 0;
    _draining = true;
    try {
      return await _drain();
    } catch (_) {
      // Deliberately silent: see this method's own doc comment. A failed
      // drain leaves the queue exactly as it was, which is the whole point
      // of the queue.
      return 0;
    } finally {
      _draining = false;
    }
  }

  Future<int> _drain() async {
    final pending = await store.loadAll();
    if (pending.isEmpty) return 0;

    // The cheap local check first, and before any socket: a logged-out node
    // keeps what it owes and sends nothing, exactly like every other
    // account-service caller in this codebase (see [AccountUpdatePoller]'s
    // "no session means no traffic, ever").
    final session = await sessionStore.load();
    if (session == null) return 0;

    final now = DateTime.now().toUtc();
    // Least-recently-failed first, so one permanently-undeliverable entry
    // can't starve the rest: the loop below stops at the first attempt that
    // looks like the service being down, and with file order it would stop
    // at the same entry every time.
    final due =
        pending.where((entry) => !entry.nextAttemptAt.isAfter(now)).toList()
          ..sort((a, b) => a.nextAttemptAt.compareTo(b.nextAttemptAt));

    var settled = 0;
    for (final entry in due) {
      // Queued as an account this node is no longer logged in as. It can
      // never be sent from here (the route is authenticated as `<me>`), so
      // keeping it would just be a permanent entry nothing ever drains.
      // Note this is *not* triggered by being logged out -- that returned
      // above -- only by being logged in as somebody else.
      final stale = entry.asAccountId != session.accountId;
      final expired = now.difference(entry.queuedAt) >= maxAge;
      if (stale || expired) {
        await _dequeue(entry);
        settled++;
        continue;
      }

      final outcome = await accountService.revokeFriendship(
        accountId: entry.asAccountId,
        friendAccountId: entry.friendAccountId,
      );
      switch (outcome) {
        case RevokeFriendshipOutcome.revoked:
        case RevokeFriendshipOutcome.refused:
          // Both are terminal: it landed, or it will never land. See
          // [RevokeFriendshipOutcome] for why a `401` is not in this branch.
          await _dequeue(entry);
          settled++;
        case RevokeFriendshipOutcome.failed:
          await store.recordFailure(
            friendAccountId: entry.friendAccountId,
            asAccountId: entry.asAccountId,
            nextAttemptAt: now.add(_backoffAfter(entry.attempts + 1)),
          );
          // Being unreachable is a property of the service, not of this
          // entry, so the rest of the queue would only pay the same timeout
          // again -- the same reason [FriendDeviceRefresher.refreshAll]
          // abandons its sweep. Nothing is lost: the next tick starts over.
          return settled;
      }
    }
    return settled;
  }

  Future<void> _dequeue(PendingRevocation entry) => store.dequeue(
    friendAccountId: entry.friendAccountId,
    asAccountId: entry.asAccountId,
  );

  /// [initialRetryDelay] doubled once per failed attempt, capped at
  /// [maxRetryDelay]. The shift is bounded before it is taken: `1 << 64` is
  /// not a large number in Dart, it is a wrong one, and an entry that has
  /// failed sixty times would otherwise come back due immediately.
  Duration _backoffAfter(int attempts) {
    if (attempts >= 32) return maxRetryDelay;
    final scaled = initialRetryDelay * (1 << (attempts - 1));
    return scaled > maxRetryDelay ? maxRetryDelay : scaled;
  }
}
