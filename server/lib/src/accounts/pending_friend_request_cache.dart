import 'account.dart';

/// The last set of still-pending friend requests this node fetched from the
/// account service -- both the ones addressed to it and the ones it sent --
/// plus when it fetched them.
///
/// [fetchedAt] is `null` exactly when this node has never had a successful
/// fetch, which is the one case a caller must not present as "you have no
/// friend requests": empty lists with a real [fetchedAt] mean the account
/// service said so, empty lists with no [fetchedAt] mean nobody has ever
/// asked.
///
/// Both directions live in one object, stamped by one [fetchedAt], because
/// they come from one fetch (see
/// [AccountServiceClient.pendingFriendRequestsOf]). Two caches would be able
/// to disagree about how current they are, and an app showing "waiting on
/// them" beside "they are waiting on you" would then be quietly mixing two
/// different moments.
class PendingFriendRequests {
  const PendingFriendRequests({
    required this.requests,
    this.outgoing = const [],
    this.fetchedAt,
  });

  const PendingFriendRequests.empty()
    : requests = const [],
      outgoing = const [],
      fetchedAt = null;

  /// The requests addressed *to* this account. Keeps its original name
  /// (rather than becoming `incoming`) because that is what every existing
  /// caller and the `{requests: [...]}` wire field already mean by it, and
  /// renaming a field to gain symmetry would be a contract change bought with
  /// nothing.
  final List<AccountFriendRequest> requests;

  /// The still-pending requests this account *sent*, which nothing could see
  /// before this existed -- so a user could not tell "they haven't answered"
  /// from "I typed the username wrong", and could not take one back.
  final List<AccountFriendRequest> outgoing;

  final DateTime? fetchedAt;

  bool get isKnown => fetchedAt != null;
}

/// Holds [PendingFriendRequests] **in memory only**, for as long as this
/// process runs.
///
/// Deliberately not persisted, unlike every other store in this module. A
/// friend request is a transient prompt that lives authoritatively on the
/// account service and that a person answers within minutes; writing it to
/// disk would create a second copy that can be wrong (a request accepted
/// from another device, or by an older run of this one), and every consumer
/// already has to handle "the service knows better" anyway. The durable
/// half of this feature is the friend list, and that has [FriendStore][].
///
/// [FriendStore]: ../federation/friend_store.dart
///
/// Written by exactly two things -- the periodic poll
/// (`federation/account_update_poller.dart`) and the app-facing
/// `GET /api/v1/account/friend-requests`, which refreshes it on the way past
/// -- and read by that same route when the account service can't be reached,
/// which is how a node with a dead relay still shows the lists it had a
/// minute ago instead of an error.
///
/// A failed fetch never touches it: [store] is only ever called with a real
/// answer, so a moment of downtime cannot silently empty a user's list.
class PendingFriendRequestCache {
  PendingFriendRequests _current = const PendingFriendRequests.empty();

  PendingFriendRequests get current => _current;

  /// Records [requests] (incoming) and [outgoing] as the current answer,
  /// stamped [fetchedAt] (now by default; a parameter only so tests can be
  /// deterministic).
  ///
  /// Both directions are replaced together, always: they were fetched
  /// together, and storing one without the other would leave a snapshot whose
  /// halves are from different moments while still carrying a single
  /// [PendingFriendRequests.fetchedAt] claiming otherwise.
  void store(
    List<AccountFriendRequest> requests, {
    List<AccountFriendRequest> outgoing = const [],
    DateTime? fetchedAt,
  }) {
    _current = PendingFriendRequests(
      requests: List.unmodifiable(requests),
      outgoing: List.unmodifiable(outgoing),
      fetchedAt: fetchedAt ?? DateTime.now().toUtc(),
    );
  }

  /// Forgets everything, back to the never-fetched state -- what logging out
  /// does, so the next user of this node is never shown the previous one's
  /// pending friend requests from memory.
  void clear() {
    _current = const PendingFriendRequests.empty();
  }
}
