enum FriendRequestStatus {
  pending,
  accepted,
  declined,

  /// An `accepted` friendship that one of the two sides has since taken
  /// back (`DELETE /accounts/<me>/friends/<accountId>`). A terminal state
  /// like [declined], and deliberately a *status* rather than the row being
  /// deleted: absence is what a bug produces, so "these two are no longer
  /// friends" has to look different on disk from "this row was lost". See
  /// [FriendRequestStore.revokeFriendship].
  ///
  /// Re-befriending afterwards works through an ordinary *new* request
  /// (`send` only ever de-duplicates against a still-`pending` one), never
  /// by flipping this row back: `_respond` refuses any transition out of a
  /// non-`pending` status, so a revoked friendship can't be resurrected by
  /// replaying an old accept.
  revoked,

  /// A `pending` request that the **sender** withdrew before it was answered
  /// (`POST /accounts/<me>/friend-requests/<id>/cancel`).
  ///
  /// A status rather than a deleted row, for exactly the reason [revoked] is
  /// one: absence is what a bug produces, so "I took this back" must not look
  /// on disk like "this row was lost". The argument is if anything stronger
  /// here than it was there -- a cancelled request is the *only* terminal
  /// state whose two parties can disagree about having seen it (the recipient
  /// may never have looked), so a row that simply vanished would leave
  /// nothing to explain why their pending list shrank.
  ///
  /// Distinct from [declined] even though both end a pending request, because
  /// they are opposite people's decisions: only the recipient can decline,
  /// only the sender can cancel, and flattening them would make
  /// `friend_requests.json` unable to say which of the two happened.
  ///
  /// Re-sending afterwards is an ordinary *new* request, same as after a
  /// [declined] or [revoked] one: `send` de-duplicates only against a still-
  /// `pending` row, and `_respond` refuses every transition out of a
  /// non-`pending` status, so a cancelled request can never be accepted by
  /// replaying an old accept.
  cancelled,
}

/// Which side of a friendship [FriendRequestStore.list] is being asked
/// about, from the point of view of the account doing the asking.
///
/// Exists because "friend requests" is genuinely two lists with one shape:
/// the ones you have to answer, and the ones you are waiting on. Before this,
/// only the first was reachable, so a user who sent a request could not tell
/// "they haven't answered yet" from "I typed the username wrong" from "it
/// never sent" -- and had no way to take it back.
enum FriendRequestDirection {
  /// Addressed *to* the asking account: what [FriendRequestStore.listAddressedTo]
  /// has always returned, and what a bare `GET /<me>/friend-requests` still
  /// means.
  incoming,

  /// Sent *by* the asking account.
  outgoing,

  /// Both at once, in one answer -- so an app that wants to show both lists
  /// (which is every app) spends one signed round trip rather than two. A
  /// request is only ever on one side of this from any one account's point of
  /// view, so nothing is ever returned twice.
  both,
}

/// A friend request between two [Account]s, addressed by accountId (not by
/// nodeId/device -- an account can have many devices, and friendship is a
/// property of the account, not any one of them). See
/// `friend_request_store.dart` for how [status] transitions are guarded.
class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.fromAccountId,
    required this.toAccountId,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String fromAccountId;
  final String toAccountId;
  final FriendRequestStatus status;
  final DateTime createdAt;

  FriendRequest copyWith({FriendRequestStatus? status}) => FriendRequest(
    id: id,
    fromAccountId: fromAccountId,
    toAccountId: toAccountId,
    status: status ?? this.status,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromAccountId': fromAccountId,
    'toAccountId': toAccountId,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
  };

  factory FriendRequest.fromJson(Map<String, dynamic> json) => FriendRequest(
    id: json['id'] as String,
    fromAccountId: json['fromAccountId'] as String,
    toAccountId: json['toAccountId'] as String,
    status: FriendRequestStatus.values.byName(json['status'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}
