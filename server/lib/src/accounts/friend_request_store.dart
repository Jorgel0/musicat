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

  /// Every request currently addressed *to* [accountId], optionally
  /// narrowed to a single [status] (e.g. `pending`, for
  /// `GET /accounts/<me>/friend-requests?status=pending`).
  /// Omitting [status] returns requests in every status.
  Future<List<FriendRequest>> listAddressedTo(
    String accountId, {
    FriendRequestStatus? status,
  }) async {
    final requests = await loadAll();
    return requests
        .where(
          (request) =>
              request.toAccountId == accountId &&
              (status == null || request.status == status),
        )
        .toList();
  }

  /// Whether [a] and [b] (accountIds) are mutual friends: an `accepted`
  /// request exists between them, in either direction -- the gate
  /// `GET /accounts/<accountId>/devices` checks.
  Future<bool> areMutualFriends(String a, String b) async {
    final requests = await loadAll();
    return requests.any(
      (request) =>
          request.status == FriendRequestStatus.accepted &&
          ((request.fromAccountId == a && request.toAccountId == b) ||
              (request.fromAccountId == b && request.toAccountId == a)),
    );
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
  /// [callerAccountId] is really its [FriendRequest.toAccountId] (the
  /// sender can never accept/decline their own request) -- checked
  /// atomically inside [_mutationLock] alongside the read, rather than by
  /// the caller doing its own [findById] first, so there's no window for a
  /// second concurrent response to race this authorization check.
  Future<(RespondOutcome, FriendRequest?)> _respond({
    required String id,
    required String callerAccountId,
    required FriendRequestStatus newStatus,
  }) => _locked(() async {
    final requests = await loadAll();
    final index = requests.indexWhere((request) => request.id == id);
    if (index == -1) return (RespondOutcome.notFound, null);

    final existing = requests[index];
    if (existing.toAccountId != callerAccountId) {
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
}
