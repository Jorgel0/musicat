import 'dart:async';

import '../accounts/account_service_client.dart';
import '../accounts/account_session_store.dart';
import '../accounts/pending_friend_request_cache.dart';
import 'account_friend_sync.dart';

/// The **poll** half of "push for convenience, poll for correctness" (the
/// same pattern ADR 0038 settled on for invite links), applied to everything
/// this node learns from the account service: who it is friends with
/// ([FriendSyncService]) and who has asked to be
/// ([PendingFriendRequestCache]).
///
/// The push half is a contentless nudge over the relay tunnel
/// (`relay/relay_protocol.dart`'s `RelayNotify`), and it is *only* a
/// latency optimization: it can be lost, it can be forged, it can never
/// arrive at all for a node whose relay is down or which has no relay
/// configured. This class is what makes the node eventually correct
/// regardless — it is the guarantee, and the push is the nicety.
///
/// Deliberately modelled on [FriendDeviceRefresher], including its
/// discipline, because the failure modes are identical: skip cheaply when
/// there is nothing to do, never let overlapping runs stampede, leave
/// everything alone on a failed fetch, and stop dead on [stop].
///
/// ## No session means no traffic. Ever.
///
/// Every tick starts by reading the local session file, and returns
/// immediately if this node isn't logged in — **before any network call, not
/// after one that fails**. A Musicat Server that never logs in to an account
/// must generate exactly as much account-service traffic as it did before
/// accounts existed, which is none, forever. The timer itself keeps ticking
/// (a few microseconds and one small local file read every
/// [pollInterval]) rather than being started and stopped by login/logout:
/// that would put lifecycle coupling between this class and two HTTP routes
/// for no behavioural gain, and a timer whose tick is a provable no-op is
/// easier to reason about than one whose existence depends on state
/// somewhere else.
///
/// ## Why [pollInterval] is what it is, and how it relates to the 30s floor
///
/// These are two different numbers doing two different jobs, and conflating
/// them is the obvious mistake:
///
/// - [FriendSyncService.minSyncInterval] (30s) is a **floor from below**. It
///   bounds how often *anything* — a burst of pushes, a user hammering the
///   login button — can make this node re-fetch. It is a rate limit.
/// - [pollInterval] (5 minutes) is a **ceiling from above**. It bounds how
///   long this node can stay wrong when *nothing* prompts it. It is a
///   staleness guarantee.
///
/// Five minutes costs 288 ticks a day, each one a signed
/// `GET /<me>/friends` plus a signed
/// `GET /<me>/friend-requests?status=pending` — 576 small requests, on the
/// order of a few hundred KB a day even with a long friend list, and zero
/// bytes for a node that never logged in. That is
/// defensible on a real mobile data plan (the constraint Jorge set for the
/// relay reconnect in ADR 0036) while keeping the worst case of "my friend
/// accepted and I can't see them yet" at five minutes on the *fallback*
/// path; on the normal path the push makes it immediate. It is deliberately
/// far more frequent than [FriendDeviceRefresher]'s 30 minutes, which bounds
/// something else entirely (how long a friend's revoked device stays trusted
/// here) and is dominated by a security/traffic trade-off rather than by
/// someone waiting in front of a screen.
class AccountUpdatePoller {
  AccountUpdatePoller({
    required this.sessionStore,
    required this.friendSync,
    required this.accountService,
    required this.pendingRequests,
    this.pollInterval = const Duration(minutes: 5),
  });

  final AccountSessionStore sessionStore;
  final FriendSyncService friendSync;
  final AccountServiceClient accountService;
  final PendingFriendRequestCache pendingRequests;

  /// How often [start] re-runs [refreshNow]. See this class's doc comment for
  /// the number and its justification. Configurable (rather than a bare
  /// constant) so tests drive it deterministically instead of waiting on
  /// wall-clock time — the same shape [FriendDeviceRefresher.refreshInterval]
  /// and `RelayClient.initialReconnectDelay` already use.
  final Duration pollInterval;

  Timer? _timer;
  bool _running = false;

  bool get isRunning => _timer != null;

  /// Starts polling. The first run happens one [pollInterval] from now, not
  /// immediately: a node that has just started has, by definition, just been
  /// through whatever else happens at startup, and a cold start firing a
  /// burst of requests at the account service is exactly what
  /// [FriendDeviceRefresher] deliberately avoids too. Calling this twice
  /// replaces the schedule rather than adding a second one.
  void start() {
    stop();
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refreshNow()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass: reconcile the friend list, then refresh the pending
  /// friend-request cache. Returns whether it got as far as talking to the
  /// account service at all.
  ///
  /// This is also what a relay push triggers (see
  /// `musicat_server_runtime.dart`), with [force] set — a push is a signal
  /// that something *just* changed, so it must not be swallowed by
  /// [FriendSyncService.minSyncInterval]. The overlap guard still applies:
  /// [force] bypasses the rate limit, never the "one run at a time" rule.
  ///
  /// A push cannot cause anything but this. It carries no data, so the worst
  /// a hostile relay achieves by sending a thousand of them is a thousand
  /// authenticated fetches this node makes of its own accord and validates
  /// itself.
  Future<bool> refreshNow({bool force = false}) async {
    if (_running) return false;
    _running = true;
    try {
      // The cheap local check, first and always: one small file read, no
      // socket. See this class's doc comment.
      final session = await sessionStore.load();
      if (session == null) return false;

      await friendSync.sync(force: force);
      await _refreshPendingRequests(session.accountId);
      return true;
    } finally {
      _running = false;
    }
  }

  /// Refreshes [PendingFriendRequestCache] from the account service, leaving
  /// it exactly as it was if the fetch didn't produce a real answer —
  /// `pendingFriendRequestsOf` collapses unreachable, refused and malformed
  /// into one `null` (see its doc comment), and all three mean the same thing
  /// here: this node learned nothing, so it forgets nothing.
  Future<void> _refreshPendingRequests(String accountId) async {
    final requests = await accountService.pendingFriendRequestsOf(accountId);
    if (requests == null) return;
    pendingRequests.store(requests);
  }
}
