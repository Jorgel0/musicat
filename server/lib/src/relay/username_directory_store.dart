import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The format every username must satisfy before [UsernameDirectory.claim]
/// (or any future caller) will accept it: alphanumeric, underscore, or
/// hyphen, 3-32 characters. URL-safe on purpose, since a username also
/// appears in `GET /directory/lookup?username=<name>`.
final RegExp usernamePattern = RegExp(r'^[a-zA-Z0-9_-]{3,32}$');

/// The exact, user-presentable message a claim fails with when the username
/// doesn't match [usernamePattern]. Shared as a constant (rather than
/// inlined separately at each call site) so a caller mapping this onto an
/// HTTP status code (see `federation_routes.dart`'s `POST
/// /api/v1/federation/username`) can match on it exactly, without the two
/// ends of that comparison silently drifting apart.
const invalidUsernameFormatError = 'Invalid username format';

/// The exact, user-presentable message a claim fails with when the username
/// is already claimed by a *different* nodeId. See
/// [invalidUsernameFormatError]'s doc comment for why this is a shared
/// constant.
const usernameAlreadyTakenError = 'Username already taken';

enum UsernameClaimOutcome { success, alreadyTaken, invalidFormat }

/// The result of a [UsernameDirectory.claim] call. [error] is `null` exactly
/// when [outcome] is [UsernameClaimOutcome.success], and otherwise one of
/// [invalidUsernameFormatError]/[usernameAlreadyTakenError] -- a plain,
/// user-presentable string, not an internal error code.
class UsernameClaimResult {
  const UsernameClaimResult._(this.outcome, this.error);

  const UsernameClaimResult.success()
    : this._(UsernameClaimOutcome.success, null);

  const UsernameClaimResult.alreadyTaken()
    : this._(UsernameClaimOutcome.alreadyTaken, usernameAlreadyTakenError);

  const UsernameClaimResult.invalidFormat()
    : this._(UsernameClaimOutcome.invalidFormat, invalidUsernameFormatError);

  final UsernameClaimOutcome outcome;
  final String? error;

  bool get success => outcome == UsernameClaimOutcome.success;
}

/// Claims [username] for [nodeId] in [usernames], enforcing [usernamePattern]
/// and the one-username-per-node/first-come-first-served rules -- shared by
/// every [UsernameDirectory] implementation below so the rules only ever
/// live in one place, regardless of how the map itself is persisted (or
/// not).
///
/// Mutates [usernames] in place on success: claiming a username already
/// owned by this exact [nodeId] is a no-op (still reported as success), and
/// claiming a *new* username releases whatever different one [nodeId]
/// previously owned, since a node has at most one at a time.
UsernameClaimResult _claimIn(
  Map<String, String> usernames,
  String username,
  String nodeId,
) {
  if (!usernamePattern.hasMatch(username)) {
    return const UsernameClaimResult.invalidFormat();
  }

  final existingOwner = usernames[username];
  if (existingOwner == nodeId) return const UsernameClaimResult.success();
  if (existingOwner != null) return const UsernameClaimResult.alreadyTaken();

  usernames.removeWhere((_, owner) => owner == nodeId);
  usernames[username] = nodeId;
  return const UsernameClaimResult.success();
}

/// What a [RelayHub] needs from wherever it keeps its `username -> nodeId`
/// directory -- implemented by [UsernameDirectoryStore] (persistent, a real
/// deployment's only sensible choice) and [InMemoryUsernameDirectory] (the
/// hub's fallback when it wasn't given a directory to persist into at all).
abstract class UsernameDirectory {
  Future<UsernameClaimResult> claim(String username, String nodeId);

  Future<String?> lookup(String username);
}

/// Persists the `username -> nodeId` directory a relay maintains so a node
/// can claim a friendly, memorable pointer to its own nodeId, to
/// `<dataDirectory>/usernames.json` -- mirrors `FriendStore`'s own
/// load-mutate-save-the-whole-file pattern. One username per node,
/// first-come-first-served (see [_claimIn]).
class UsernameDirectoryStore implements UsernameDirectory {
  UsernameDirectoryStore(this.dataDirectory);

  final Directory dataDirectory;

  File get _file => File(p.join(dataDirectory.path, 'usernames.json'));

  Future<Map<String, String>> _loadAll() async {
    final file = _file;
    if (!file.existsSync()) return {};
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return json.map((key, value) => MapEntry(key, value as String));
  }

  Future<void> _save(Map<String, String> usernames) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(jsonEncode(usernames));
  }

  @override
  Future<UsernameClaimResult> claim(String username, String nodeId) async {
    final usernames = await _loadAll();
    final result = _claimIn(usernames, username, nodeId);
    if (result.success) await _save(usernames);
    return result;
  }

  @override
  Future<String?> lookup(String username) async => (await _loadAll())[username];
}

/// An in-memory-only [UsernameDirectory] -- what a [RelayHub] constructed
/// without a `dataDir` falls back to, so existing callers that never had a
/// persistent directory to begin with (unit tests, `bin/relay.dart` if run
/// with no data directory configured) keep working. Every claim vanishes the
/// moment the process restarts; a real deployment should always construct
/// [RelayHub] with a real `dataDir` instead so usernames actually survive a
/// restart.
class InMemoryUsernameDirectory implements UsernameDirectory {
  final Map<String, String> _usernames = {};

  @override
  Future<UsernameClaimResult> claim(String username, String nodeId) async =>
      _claimIn(_usernames, username, nodeId);

  @override
  Future<String?> lookup(String username) async => _usernames[username];
}
