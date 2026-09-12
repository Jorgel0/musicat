import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'friend_request.dart';

String _generateId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Which of a request's two accounts is taking an action on it -- the only
/// thing that differs between answering a request and withdrawing one. See
/// [FriendRequestStore._respond].
enum _RequestSide { recipient, sender }

enum RespondOutcome {
  updated,
  alreadyInThatState,
  conflict,
  notFound,
  forbidden,
}

/// Persists every [FriendRequest] to `<dataDirectory>/friend_requests.json`
/// -- same load-mutate-save-the-whole-file pattern as `AccountStore`/
/// `FriendStore`/`UsernameDirectoryStore`.
class FriendRequestStore {
  FriendRequestStore(this.dataDirectory);

  final Directory dataDirectory;

  /// Serializes [send]/[accept]/[decline] the same way
  /// `AccountStore._mutationLock` serializes its own mutations -- [send] in
  /// particular has the same check-then-write shape as a username claim
  /// (see that class's own doc comment): without this, two near-
  /// simultaneous `send` calls for the same (from, to) pair could both see
  /// "no pending request yet" and both create one.
  Future<void> _mutationLock = Future<void>.value();

  File get _file => File(p.join(dataDirectory.path, 'friend_requests.json'));

  Future<List<FriendRequest>> loadAll() async {
    final file = _file;
    if (!file.existsSync()) return [];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return [
      for (final entry in json)
        FriendRequest.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<void> _save(List<FriendRequest> requests) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final request in requests) request.toJson()]),
    );
  }

  Future<FriendRequest?> findById(String id) async {
    final requests = await loadAll();
    for (final request in requests) {
      if (request.id == id) return request;
    }
    return null;
  }

  /// Every request [accountId] is on the [direction] side of, optionally
  /// narrowed to a single [status] (e.g. `pending`, for
  /// `GET /accounts/<me>/friend-requests?status=pending`).
  /// Omitting [status] returns requests in every status.
  ///
  /// One method for all three directions rather than one per direction:
  /// they differ only in which field is compared to [accountId], and the
  /// authorization, the status filter and the username projection that wrap
  /// them are identical -- two implementations would be free to drift on
  /// which statuses they include, which is precisely the kind of drift that
  /// shows a user a request they have already answered.
  ///
  /// Order is the file's own (oldest first), and stable across directions:
  /// [FriendRequestDirection.both] does not group by side, it filters one
  /// pass over the same list, so a caller diffing successive responses sees
  /// real changes rather than reordering.
  Future<List<FriendRequest>> list(
    String accountId, {
    FriendRequestDirection direction = FriendRequestDirection.incoming,
    FriendRequestStatus? status,
  }) async {
    final requests = await loadAll();
    return requests
        .where(
          (request) =>
              _isOn(request, accountId, direction) &&
              (status == null || request.status == status),
        )
        .toList();
  }

  static bool _isOn(
    FriendRequest request,
    String accountId,
    FriendRequestDirection direction,
  ) => switch (direction) {
    FriendRequestDirection.incoming => request.toAccountId == accountId,
    FriendRequestDirection.outgoing => request.fromAccountId == accountId,
    FriendRequestDirection.both =>
      request.toAccountId == accountId || request.fromAccountId == accountId,
  };

  /// [list]'s incoming case, kept under its original name because that is
  /// what every existing call site means and reads better than a direction
  /// argument spelled out at each of them. A one-line delegation, so the two
  /// cannot disagree.
  Future<List<FriendRequest>> listAddressedTo(
    String accountId, {
    FriendRequestStatus? status,
  }) => list(
    accountId,
    direction: FriendRequestDirection.incoming,
    status: status,
  );

  /// If [request] is an `accepted` friendship that [accountId] is one side
  /// of, who the *other* side is; `null` otherwise.
  ///
  /// The single definition of the both-directions rule -- "friendship is
  /// symmetric once accepted, no matter who sent the request" -- that both
  /// [areMutualFriends] and [listAcceptedFriendAccountIds] are phrased in
  /// terms of. Written once rather than twice on purpose: the two are the
  /// same question asked from different ends (`is X in my friend list` vs
  /// `what is my friend list`), and two independent encodings of it would be
  /// free to drift into disagreeing -- which, since one of them gates
  /// `GET /accounts/<accountId>/devices` and the other decides what
  /// `GET /accounts/<me>/friends` discloses, would be a disclosure bug
  /// rather than a cosmetic one.
  static String? _acceptedCounterpartOf(
    FriendRequest request,
    String accountId,
  ) {
    if (request.status != FriendRequestStatus.accepted) return null;
    if (request.fromAccountId == accountId) return request.toAccountId;
    if (request.toAccountId == accountId) return request.fromAccountId;
    return null;
  }

  /// Whether [a] and [b] (accountIds) are mutual friends: an `accepted`
  /// request exists between them, in either direction -- the gate
  /// `GET /accounts/<accountId>/devices` checks.
  Future<bool> areMutualFriends(String a, String b) async {
    final requests = await loadAll();
    return requests.any((request) => _acceptedCounterpartOf(request, a) == b);
  }

  /// Every account [accountId] is currently friends with -- the accepted
  /// half of [listAddressedTo]'s data, from both directions at once, which
  /// is what `GET /accounts/<me>/friends` needs and what no existing method
  /// could answer ([listAddressedTo] only ever sees *incoming* requests, so
  /// on its own it silently omits every friend this account was the one to
  /// ask).
  ///
  /// De-duplicated: two accounts that each sent *and* accepted a request in
  /// the opposite direction are one friend, not two. Order is stable (first
  /// accepted request first), so a caller diffing successive responses sees
  /// real changes rather than reordering.
  Future<List<String>> listAcceptedFriendAccountIds(String accountId) async {
    final requests = await loadAll();
    final counterparts = <String>{};
    for (final request in requests) {
      final other = _acceptedCounterpartOf(request, accountId);
      if (other != null) counterparts.add(other);
    }
    return counterparts.toList();
  }

  Future<T> _locked<T>(Future<T> Function() operation) {
    final previous = _mutationLock;
    final result = previous.then((_) => operation());
    _mutationLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Creates a pending request from [fromAccountId] to [toAccountId], or --
  /// if one is already pending in that same direction -- returns the
  /// existing one unchanged instead of creating a second (see
  /// `account_routes.dart`'s doc comment on
  /// `POST /accounts/<me>/friend-requests` for the exact idempotency rule).
  /// Guarded by [_mutationLock] for the same check-then-write reason as
  /// `UsernameDirectoryStore.claim`.
  Future<FriendRequest> send(String fromAccountId, String toAccountId) =>
      _locked(() async {
        final requests = await loadAll();
        for (final request in requests) {
          if (request.fromAccountId == fromAccountId &&
              request.toAccountId == toAccountId &&
              request.status == FriendRequestStatus.pending) {
            return request;
          }
        }

        final request = FriendRequest(
          id: _generateId(),
          fromAccountId: fromAccountId,
          toAccountId: toAccountId,
          status: FriendRequestStatus.pending,
          createdAt: DateTime.now().toUtc(),
        );
        requests.add(request);
        await _save(requests);
        return request;
      });

  /// Flips the request [id]'s status to [newStatus], but only if
  /// [callerAccountId] really is the [actor] side of it -- checked
  /// atomically inside [_mutationLock] alongside the read, rather than by
  /// the caller doing its own [findById] first, so there's no window for a
  /// second concurrent response to race this authorization check.
  ///
  /// [actor] is what makes accept/decline and cancel one operation instead of
  /// two near-identical ones: they differ *only* in which side of the request
  /// is allowed to act (the recipient answers an offer; the sender withdraws
  /// it), and every other rule -- unknown id, already in that state, already
  /// terminal, write-under-the-lock -- is the same rule. Two copies would be
  /// free to drift on the one thing here that is a permission check.
  Future<(RespondOutcome, FriendRequest?)> _respond({
    required String id,
    required String callerAccountId,
    required FriendRequestStatus newStatus,
    _RequestSide actor = _RequestSide.recipient,
  }) => _locked(() async {
    final requests = await loadAll();
    final index = requests.indexWhere((request) => request.id == id);
    if (index == -1) return (RespondOutcome.notFound, null);

    final existing = requests[index];
    final actingAccountId = switch (actor) {
      _RequestSide.recipient => existing.toAccountId,
      _RequestSide.sender => existing.fromAccountId,
    };
    if (actingAccountId != callerAccountId) {
      return (RespondOutcome.forbidden, existing);
    }
    if (existing.status == newStatus) {
      return (RespondOutcome.alreadyInThatState, existing);
    }
    if (existing.status != FriendRequestStatus.pending) {
      return (RespondOutcome.conflict, existing);
    }

    final updated = existing.copyWith(status: newStatus);
    requests[index] = updated;
    await _save(requests);
    return (RespondOutcome.updated, updated);
  });

  Future<(RespondOutcome, FriendRequest?)> accept(
    String id,
    String callerAccountId,
  ) => _respond(
    id: id,
    callerAccountId: callerAccountId,
    newStatus: FriendRequestStatus.accepted,
  );

  Future<(RespondOutcome, FriendRequest?)> decline(
    String id,
    String callerAccountId,
  ) => _respond(
    id: id,
    callerAccountId: callerAccountId,
    newStatus: FriendRequestStatus.declined,
  );

  /// Withdraws the still-pending request [id], which only its **sender** may
  /// do ([RespondOutcome.forbidden] for anyone else, the recipient very much
  /// included -- their way out is [decline], and the two are recorded
  /// differently on purpose; see [FriendRequestStatus.cancelled]).
  ///
  /// [RespondOutcome.conflict] once it has been answered: a request the other
  /// side already accepted is a friendship, and ending one of those is
  /// [revokeFriendship]'s job, not this one. Cancelling an already-cancelled
  /// request is [RespondOutcome.alreadyInThatState], so a retry is free.
  Future<(RespondOutcome, FriendRequest?)> cancel(
    String id,
    String callerAccountId,
  ) => _respond(
    id: id,
    callerAccountId: callerAccountId,
    newStatus: FriendRequestStatus.cancelled,
    actor: _RequestSide.sender,
  );

  /// Ends the friendship between [a] and [b], whichever of them sent the
  /// original request: every `accepted` request between the two is flipped
  /// to [FriendRequestStatus.revoked]. Returns how many rows that was --
  /// `0` meaning they were not friends, which is a perfectly ordinary
  /// outcome and not an error (see `account_routes.dart`'s
  /// `DELETE /<me>/friends/<accountId>`, which is idempotent).
  ///
  /// **Either side may call this**, which is the whole point: [_respond]'s
  /// rule that only a request's *recipient* may act on it is about
  /// answering an offer, and an established friendship is no longer an
  /// offer. Phrased in terms of [_acceptedCounterpartOf] like
  /// [areMutualFriends] and [listAcceptedFriendAccountIds], so all three
  /// agree by construction about what "friends" means -- the disagreement
  /// that method's own doc comment warns about would here mean revoking
  /// something that still gates a device-list disclosure.
  ///
  /// *Every* matching row, not just the first: two accounts that each sent
  /// and each accepted a request have two accepted rows for one friendship
  /// ([listAcceptedFriendAccountIds] already de-duplicates them into one
  /// friend), and leaving either one behind would leave them mutual friends
  /// after a revocation that reported success.
  ///
  /// Nothing else is touched: a `pending` request between the two survives
  /// as pending (it is a separate, still-unanswered offer), and this writes
  /// nothing at all when there is nothing to revoke, so a retried
  /// revocation costs one file read.
  Future<int> revokeFriendship(String a, String b) => _locked(() async {
    final requests = await loadAll();
    var revoked = 0;
    for (var i = 0; i < requests.length; i++) {
      if (_acceptedCounterpartOf(requests[i], a) != b) continue;
      requests[i] = requests[i].copyWith(status: FriendRequestStatus.revoked);
      revoked++;
    }
    if (revoked > 0) await _save(requests);
    return revoked;
  });
}
