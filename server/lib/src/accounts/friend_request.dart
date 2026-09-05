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
