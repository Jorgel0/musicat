import 'account.dart';

/// The last set of incoming, still-pending friend requests this node fetched
/// from the account service, plus when it fetched them.
///
/// [fetchedAt] is `null` exactly when this node has never had a successful
/// fetch, which is the one case a caller must not present as "you have no
/// friend requests": an empty list with a real [fetchedAt] means the account
/// service said so, an empty list with no [fetchedAt] means nobody has ever
/// asked.
class PendingFriendRequests {
  const PendingFriendRequests({required this.requests, this.fetchedAt});

  const PendingFriendRequests.empty() : requests = const [], fetchedAt = null;

  final List<AccountFriendRequest> requests;
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
/// which is how a node with a dead relay still shows the list it had a
/// minute ago instead of an error.
///
/// A failed fetch never touches it: [store] is only ever called with a real
/// answer, so a moment of downtime cannot silently empty a user's list.
class PendingFriendRequestCache {
  PendingFriendRequests _current = const PendingFriendRequests.empty();

  PendingFriendRequests get current => _current;

  /// Records [requests] as the current answer, stamped [fetchedAt] (now by
  /// default; a parameter only so tests can be deterministic).
  void store(List<AccountFriendRequest> requests, {DateTime? fetchedAt}) {
    _current = PendingFriendRequests(
      requests: List.unmodifiable(requests),
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
