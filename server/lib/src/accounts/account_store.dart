import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../relay/username_directory_store.dart' show usernamePattern;
import 'account.dart';
import 'password_hashing.dart';

String _generateId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

enum LoginOutcome { created, linked, wrongPassword, invalidUsername }

/// The result of [AccountStore.loginOrSignup]. [account] is non-null
/// exactly when [outcome] is [LoginOutcome.created] or
/// [LoginOutcome.linked].
class LoginResult {
  const LoginResult._(this.outcome, this.account);

  const LoginResult.created(Account account)
    : this._(LoginOutcome.created, account);

  const LoginResult.linked(Account account)
    : this._(LoginOutcome.linked, account);

  const LoginResult.wrongPassword() : this._(LoginOutcome.wrongPassword, null);

  const LoginResult.invalidUsername()
    : this._(LoginOutcome.invalidUsername, null);

  final LoginOutcome outcome;
  final Account? account;
}

/// Persists every [Account] to `<dataDirectory>/accounts.json` -- mirrors
/// `FriendStore`/`UsernameDirectoryStore`'s own load-mutate-save-the-whole-
/// file pattern, including the same username format rule
/// (`usernamePattern`, `relay/username_directory_store.dart`) so accounts
/// and the existing username directory feel like the same namespace
/// convention to a user, even though they're separate stores.
class AccountStore {
  AccountStore(this.dataDirectory);

  final Directory dataDirectory;

  /// Serializes every mutating call on *this* store instance
  /// ([loginOrSignup] and [unlinkDevice]) so their load-mutate-save cycles
  /// can never interleave with each other -- exactly
  /// `UsernameDirectoryStore._claimLock`'s own reasoning (see its doc
  /// comment, and the regression test it names, issue #8): without this,
  /// two concurrent `login/complete` calls for a *username that doesn't
  /// exist yet* could both read the file before either writes it back,
  /// both see it as unclaimed, and both create a conflicting account for
  /// the same username. Every [loginOrSignup] call goes through this same
  /// lock end to end -- not just its signup branch -- including the login
  /// branch's Argon2id password verification (~200ms at
  /// [Argon2Params.recommended]), which is a deliberate
  /// simplicity-over-throughput trade-off: fine for a small self-hosted
  /// service, where briefly serializing unrelated concurrent logins too
  /// (not just concurrent signups for the same username) is an acceptable
  /// cost for never risking the check-then-write race. A later round could
  /// narrow this to just the check-then-write section if it ever becomes a
  /// real bottleneck.
  Future<void> _mutationLock = Future<void>.value();

  File get _file => File(p.join(dataDirectory.path, 'accounts.json'));

  Future<List<Account>> loadAll() async {
    final file = _file;
    if (!file.existsSync()) return [];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return [
      for (final entry in json) Account.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<void> _save(List<Account> accounts) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final account in accounts) account.toJson()]),
    );
  }

  Future<Account?> findByUsername(String username) async {
    final accounts = await loadAll();
    for (final account in accounts) {
      if (account.username == username) return account;
    }
    return null;
  }

  Future<Account?> findById(String accountId) async {
    final accounts = await loadAll();
    for (final account in accounts) {
      if (account.accountId == accountId) return account;
    }
    return null;
  }

  /// Finds whichever account currently has [nodeId] linked as one of its
  /// own devices -- the lookup behind `GET /accounts/by-device/<nodeId>`
  /// and every account route's own signed-request authentication (see
  /// `account_request_auth.dart`).
  Future<Account?> findByDeviceNodeId(String nodeId) async {
    final accounts = await loadAll();
    for (final account in accounts) {
      if (account.devices.any((device) => device.nodeId == nodeId)) {
        return account;
      }
    }
    return null;
  }

  Future<T> _locked<T>(Future<T> Function() operation) {
    final previous = _mutationLock;
    final result = previous.then((_) => operation());
    _mutationLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// The signup-or-login device-linking mutation this round's brief
  /// specifies: if [username] doesn't have an account yet, creates one
  /// (hashing [password] fresh under [Argon2Params.recommended]) and links
  /// [nodeId]/[publicKeyBase64] as its first device; if it does, verifies
  /// [password] against the stored hash (using *that account's own*
  /// stored params, see [Account.storedPasswordHash]) and, if correct,
  /// links [nodeId]/[publicKeyBase64] as an additional device -- a no-op
  /// if already linked, never a second, conflicting account, and never any
  /// mutation at all on a wrong password. Guarded end to end by
  /// [_mutationLock] (see its own doc comment).
  ///
  /// Callers must already have verified the caller genuinely controls
  /// [nodeId]/[publicKeyBase64] (the self-certifying nodeId check and the
  /// signed-nonce check, see `account_routes.dart`'s `POST
  /// /login/complete`) *before* calling this -- this method itself trusts
  /// them as given.
  ///
  /// [relayUrl] is the logging-in device's own relay endpoint (see
  /// [DeviceLink.relayUrl]) and **every login is a full refresh of it**,
  /// including the already-linked, otherwise-idempotent case: a device that
  /// changed relays, or stopped using one, says so by logging in again, and
  /// `null` therefore means "I have no relay right now", not "leave whatever
  /// you had". Keeping a stale endpoint would send this device's friends to
  /// a relay it is no longer connected to, which costs them a wasted
  /// reachability attempt each time and can never succeed.
  Future<LoginResult> loginOrSignup({
    required String username,
    required String password,
    required String nodeId,
    required String publicKeyBase64,
    String? relayUrl,
  }) => _locked(
    () => _loginOrSignupLocked(
      username: username,
      password: password,
      nodeId: nodeId,
      publicKeyBase64: publicKeyBase64,
      relayUrl: relayUrl,
    ),
  );

  Future<LoginResult> _loginOrSignupLocked({
    required String username,
    required String password,
    required String nodeId,
    required String publicKeyBase64,
    String? relayUrl,
  }) async {
    if (!usernamePattern.hasMatch(username)) {
      return const LoginResult.invalidUsername();
    }

    final accounts = await loadAll();
    final index = accounts.indexWhere(
      (account) => account.username == username,
    );
    final now = DateTime.now().toUtc();

    if (index == -1) {
      final hashed = await hashPassword(password);
      final account = Account(
        accountId: _generateId(),
        username: username,
        passwordHash: hashed.hash,
        passwordSalt: hashed.salt,
        argon2Params: hashed.params,
        devices: [
          DeviceLink(
            nodeId: nodeId,
            publicKeyBase64: publicKeyBase64,
            linkedAt: now,
            relayUrl: relayUrl,
          ),
        ],
        createdAt: now,
      );
      accounts.add(account);
      await _save(accounts);
      return LoginResult.created(account);
    }

    final account = accounts[index];
    final passwordIsValid = await verifyPassword(
      password,
      account.storedPasswordHash,
    );
    if (!passwordIsValid) return const LoginResult.wrongPassword();

    final existingIndex = account.devices.indexWhere(
      (device) => device.nodeId == nodeId,
    );
    if (existingIndex != -1) {
      final existing = account.devices[existingIndex];
      // Still idempotent in the sense that matters -- no second device row,
      // and [DeviceLink.linkedAt] keeps its original value, so re-logging in
      // never reshuffles a friend's reachability preference order
      // (`Friend.devicesByPreference`). What a re-login *does* refresh is
      // [DeviceLink.relayUrl]; if that hasn't changed either, nothing is
      // written at all.
      if (existing.relayUrl == relayUrl) return LoginResult.linked(account);

      final devices = [...account.devices];
      devices[existingIndex] = DeviceLink(
        nodeId: existing.nodeId,
        publicKeyBase64: existing.publicKeyBase64,
        linkedAt: existing.linkedAt,
        relayUrl: relayUrl,
      );
      final refreshed = account.copyWith(devices: devices);
      accounts[index] = refreshed;
      await _save(accounts);
      return LoginResult.linked(refreshed);
    }

    final updated = account.copyWith(
      devices: [
        ...account.devices,
        DeviceLink(
          nodeId: nodeId,
          publicKeyBase64: publicKeyBase64,
          linkedAt: now,
          relayUrl: relayUrl,
        ),
      ],
    );
    accounts[index] = updated;
    await _save(accounts);
    return LoginResult.linked(updated);
  }

  /// Unlinks [nodeId] from [accountId]'s device list, if it's currently
  /// linked there -- a no-op (still returns `true`) otherwise, matching
  /// `DELETE`'s usual idempotence. Returns `false` only if [accountId]
  /// itself isn't a known account at all.
  Future<bool> unlinkDevice(String accountId, String nodeId) =>
      _locked(() => _unlinkDeviceLocked(accountId, nodeId));

  Future<bool> _unlinkDeviceLocked(String accountId, String nodeId) async {
    final accounts = await loadAll();
    final index = accounts.indexWhere(
      (account) => account.accountId == accountId,
    );
    if (index == -1) return false;

    final account = accounts[index];
    accounts[index] = account.copyWith(
      devices: account.devices
          .where((device) => device.nodeId != nodeId)
          .toList(),
    );
    await _save(accounts);
    return true;
  }
}
