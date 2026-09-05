import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Which portable account (ADR 0048) *this* node is currently logged in as.
///
/// Deliberately tiny, and deliberately missing the one field a session-token
/// design would need: **there is no credential here at all.** After
/// `POST /accounts/login/complete` succeeds, this device is a linked device
/// of the account, and from then on it proves "I act for account
/// [accountId]" by signing requests with its own existing Ed25519 node key
/// -- the same key it already signs every federation request with. So the
/// only thing worth persisting is *which* account that is.
///
/// That property is the reason the password is never stored, echoed, or
/// logged anywhere: a stolen device compromises that device (revocable by
/// unlinking it from any other device on the account, with
/// `DELETE /accounts/<accountId>/devices/<nodeId>`), not the account itself.
/// A cached password -- or a long-lived bearer token, which is the same
/// problem wearing a different hat -- would turn a stolen phone into a full
/// account takeover, and there would be nothing to revoke it with.
class AccountSession {
  const AccountSession({
    required this.accountId,
    required this.username,
    required this.loggedInAt,
  });

  final String accountId;

  /// The account's username as the account service reported it back --
  /// stored purely so this node's own app can show "logged in as X" without
  /// a network call. Never used to authorize anything; [accountId] is the
  /// identity.
  final String username;

  final DateTime loggedInAt;

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'username': username,
    'loggedInAt': loggedInAt.toIso8601String(),
  };

  factory AccountSession.fromJson(Map<String, dynamic> json) => AccountSession(
    accountId: json['accountId'] as String,
    username: json['username'] as String,
    loggedInAt: DateTime.parse(json['loggedInAt'] as String),
  );
}

/// Persists the single [AccountSession] this node is logged in as to
/// `<dataDirectory>/account_session.json`, or nothing at all if it is logged
/// in as nobody.
///
/// **At most one session, ever.** A Musicat Server is one person's node; two
/// accounts sharing one node would make "which account is this" ambiguous on
/// every path that consults it (the friend sync below all, but also anything
/// later that acts *as* the account), so [save] replaces rather than
/// appends. Several *devices* per account is the supported multiplicity, and
/// it lives on the account service's side, not here.
///
/// Purely local, like every other store in this module's node-side half: it
/// holds no HTTP client and makes no network call. Reading who this node is
/// must keep working with the account service unreachable -- that is Rule 1
/// applied to this store (see `docs/adr/0049-*.md`).
class AccountSessionStore {
  AccountSessionStore(this.dataDirectory);

  final Directory dataDirectory;

  /// Serializes [save] and [clear] the same plain `Future`-chaining way
  /// `AccountStore._mutationLock` and `FriendStore._locked` already do (see
  /// their doc comments, and issue #8). There is only one record here, so
  /// there is no load-mutate-save window to lose an update in -- but a
  /// `clear()` (logout) landing between a concurrent `save()`'s file write
  /// and its own delete could still leave the just-deleted file recreated,
  /// i.e. a logout that silently didn't happen. Same lock as everywhere
  /// else rather than a new mechanism, so there is one shape to review.
  ///
  /// [load] stays outside the lock deliberately: it is a pure read, and
  /// every caller that matters (the sync service, `GET /api/v1/account`)
  /// tolerates reading the state from just before a concurrent mutation.
  Future<void> _mutationLock = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() operation) {
    final previous = _mutationLock;
    final result = previous.then((_) => operation());
    _mutationLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  File get _file => File(p.join(dataDirectory.path, 'account_session.json'));

  /// The current session, or `null` if this node isn't logged in to any
  /// account (including the entirely normal case of a node that never has
  /// been -- accounts are optional, see `startMusicatServer`).
  ///
  /// Treats an unreadable or corrupt file as "no session" rather than
  /// throwing: being logged out is a recoverable state the user can fix by
  /// logging in again, whereas an exception here would propagate into
  /// [FriendSyncService] and every request to `GET /api/v1/account`.
  Future<AccountSession?> load() async {
    final file = _file;
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return AccountSession.fromJson(json as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Records that this node is now logged in as [accountId]/[username],
  /// replacing any previous session, and returns what was stored.
  ///
  /// [loggedInAt] defaults to now; it is a parameter only so tests can be
  /// deterministic. Note what is *not* a parameter: the password used to
  /// log in. It never reaches this class.
  Future<AccountSession> save({
    required String accountId,
    required String username,
    DateTime? loggedInAt,
  }) => _locked(() async {
    final session = AccountSession(
      accountId: accountId,
      username: username,
      loggedInAt: loggedInAt ?? DateTime.now().toUtc(),
    );
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(jsonEncode(session.toJson()));
    return session;
  });

  /// Logs this node out, returning whether there was a session to clear.
  ///
  /// Deletes the file rather than writing an empty one, so "logged out" and
  /// "never logged in" are the same on-disk state and there is only one case
  /// for [load] to handle.
  ///
  /// **Only the session.** This deliberately does not touch `FriendStore` --
  /// see `account_app_routes.dart`'s `DELETE /api/v1/account`.
  Future<bool> clear() => _locked(() async {
    final file = _file;
    if (!file.existsSync()) return false;
    await file.delete();
    return true;
  });
}
