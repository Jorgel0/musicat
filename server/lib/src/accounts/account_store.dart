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

/// The one canonical spelling of [username] -- what is stored, what is
/// looked up, and what every response echoes back.
///
/// Usernames are **case-insensitive**, because the alternative was a trap
/// with no floor: `usernamePattern` allows both cases, an unknown username
/// used to take the *create* branch with no confirmation, and so typing
/// `Jorge` instead of `jorge` on a second device silently made a second,
/// empty account, stranded that device on it, and handed the other spelling
/// to whoever asked for it next.
///
/// Nothing preserves the casing the user typed, deliberately: there is no
/// display-name field to keep it in, and the login response already
/// documents its `username` as the canonical spelling rather than whatever
/// the caller sent (see `AccountLoginResult.username`). One spelling, in one
/// place, is the whole point.
String normalizeUsername(String username) => username.toLowerCase();

/// The shortest password [AccountStore.loginOrSignup] will create an account
/// with. NIST SP 800-63B's floor for a user-chosen memorized secret, and the
/// only length rule here -- no composition rules, no maximum.
///
/// **Enforced on creation only, never on login.** An account created before
/// this existed may well have a one-character password (the previous check
/// was `password.isEmpty`, nothing more), and refusing to let its owner log
/// in would lock them out of their own account to punish a decision the
/// service allowed them to make.
const int minPasswordLength = 8;

enum LoginOutcome {
  created,
  linked,
  wrongPassword,
  invalidUsername,

  /// No account holds this username and the caller asked not to create one
  /// (`allowCreate: false`). See [AccountStore.loginOrSignup].
  noSuchAccount,

  /// The password offered for a *new* account is shorter than
  /// [minPasswordLength]. Never returned for a login.
  passwordTooShort,

  /// Two or more stored accounts normalize to this same username -- only
  /// possible for data written before usernames were case-insensitive. Not
  /// resolvable here without picking a winner, which would silently shadow
  /// somebody's account, so it is reported instead. See
  /// [AccountStore.findAllByUsername].
  ambiguousUsername,
}

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

  const LoginResult.noSuchAccount() : this._(LoginOutcome.noSuchAccount, null);

  const LoginResult.passwordTooShort()
    : this._(LoginOutcome.passwordTooShort, null);

  const LoginResult.ambiguousUsername()
    : this._(LoginOutcome.ambiguousUsername, null);

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

  /// The account holding [username], matched **case-insensitively** (see
  /// [normalizeUsername]), or `null` if there is none.
  ///
  /// With two stored accounts that differ only by case -- impossible to
  /// create now, but possible in data written before this rule existed --
  /// only the *exact* spelling resolves, and neither entry is touched,
  /// merged or hidden from [loadAll]. That is a deterministic precedence
  /// rule in the same spirit as [FriendStore.findByDeviceNodeId]'s, and the
  /// alternative (picking one of them) would silently hand one person's
  /// friend requests to the other. Logging in refuses outright in that state
  /// rather than choosing: see [findAllByUsername] and
  /// [LoginOutcome.ambiguousUsername].
  ///
  /// [FriendStore.findByDeviceNodeId]: ../federation/friend_store.dart
  Future<Account?> findByUsername(String username) async {
    final matches = await findAllByUsername(username);
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.single;
    for (final account in matches) {
      if (account.username == username) return account;
    }
    return null;
  }

  /// Every stored account whose username normalizes to [username]'s -- one
  /// entry in every case this service can still produce, and more only for
  /// accounts written before usernames were case-insensitive.
  ///
  /// Exists so that state is *detected and reported* rather than papered
  /// over: nothing in this class merges two such accounts, renames one, or
  /// drops one, because each may have its own password, its own devices and
  /// its own friendships, and picking a winner would silently strand the
  /// other. An operator resolves it by editing `accounts.json` (there is no
  /// safe automatic answer -- which of the two keeps the name is a question
  /// only its owners can settle).
  Future<List<Account>> findAllByUsername(String username) async {
    final normalized = normalizeUsername(username);
    return [
      for (final account in await loadAll())
        if (normalizeUsername(account.username) == normalized) account,
    ];
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
  ///
  /// **A device is linked to at most one account at a time**, enforced by
  /// [loginOrSignup] unlinking it from every other one, so there is nothing
  /// here to disambiguate. Before that rule, this returned whichever account
  /// happened to come first in `accounts.json`, which meant a device that had
  /// ever linked to account A kept authenticating as A no matter what it
  /// signed in as afterwards: logging in as B answered `200 created:true` and
  /// then every account route answered `403 Cannot act as another account`,
  /// with no way out from the app.
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
  ///
  /// [deviceName] (see [DeviceLink.deviceName]) is refreshed on exactly the
  /// same terms and for the same reason: it is something the node says about
  /// itself right now, not a stored preference, so `null` means "I did not
  /// say" and overwrites whatever was there.
  ///
  /// [username] is matched and stored **case-insensitively**
  /// ([normalizeUsername]); [LoginOutcome.ambiguousUsername] reports the one
  /// state that cannot be resolved that way (two pre-existing accounts
  /// differing only by case) rather than picking one of them.
  ///
  /// [allowCreate] defaults to `true`, which is exactly what this method has
  /// always done. Passing `false` turns "there is no such account" from a
  /// signup into a [LoginOutcome.noSuchAccount] refusal that writes nothing
  /// and hashes nothing -- the opt-in the app needs so a mistyped username
  /// asks "create a new account?" instead of silently becoming one.
  ///
  /// **Logging in unlinks [nodeId] from every other account.** A device acts
  /// for one account at a time; see [findByDeviceNodeId] for what the absence
  /// of that rule did. It is safe to do here and nowhere else, because
  /// reaching this line takes both the target account's password *and* a
  /// signature from the device itself, so only that device's own owner can
  /// trigger it -- and it belongs on the login path specifically, never on
  /// logout, which is purely local, works offline, and deliberately keeps
  /// this node's friends.
  Future<LoginResult> loginOrSignup({
    required String username,
    required String password,
    required String nodeId,
    required String publicKeyBase64,
    String? relayUrl,
    String? deviceName,
    bool allowCreate = true,
  }) => _locked(
    () => _loginOrSignupLocked(
      username: username,
      password: password,
      nodeId: nodeId,
      publicKeyBase64: publicKeyBase64,
      relayUrl: relayUrl,
      deviceName: deviceName,
      allowCreate: allowCreate,
    ),
  );

  Future<LoginResult> _loginOrSignupLocked({
    required String username,
    required String password,
    required String nodeId,
    required String publicKeyBase64,
    String? relayUrl,
    String? deviceName,
    required bool allowCreate,
  }) async {
    final canonicalUsername = normalizeUsername(username);
    if (!usernamePattern.hasMatch(canonicalUsername)) {
      return const LoginResult.invalidUsername();
    }

    final accounts = await loadAll();
    final matches = [
      for (var i = 0; i < accounts.length; i++)
        if (normalizeUsername(accounts[i].username) == canonicalUsername) i,
    ];
    // Refused rather than resolved: with two accounts differing only by case
    // (only possible in data written before this rule), logging either of
    // them in means choosing which one owns the name, and choosing wrong
    // hands somebody the other person's friendships. See
    // [findAllByUsername].
    if (matches.length > 1) return const LoginResult.ambiguousUsername();
    final index = matches.isEmpty ? -1 : matches.single;
    final now = DateTime.now().toUtc();

    if (index == -1) {
      // Both checks before the Argon2id hash, which is the expensive part:
      // there is no reason to spend 200ms deriving a key for a request that
      // is about to be refused.
      if (!allowCreate) return const LoginResult.noSuchAccount();
      if (password.length < minPasswordLength) {
        return const LoginResult.passwordTooShort();
      }
      final hashed = await hashPassword(password);
      final account = Account(
        accountId: _generateId(),
        username: canonicalUsername,
        passwordHash: hashed.hash,
        passwordSalt: hashed.salt,
        argon2Params: hashed.params,
        devices: [
          DeviceLink(
            nodeId: nodeId,
            publicKeyBase64: publicKeyBase64,
            linkedAt: now,
            relayUrl: relayUrl,
            deviceName: deviceName,
            lastLoginAt: now,
          ),
        ],
        createdAt: now,
      );
      accounts.add(account);
      // A brand-new account is still a new home for this device, so the
      // device leaves whatever account it was on before -- otherwise
      // `findByDeviceNodeId` would keep answering with the old one and the
      // account just created would be unusable from the device that made it.
      _unlinkFromOtherAccounts(accounts, nodeId, keep: accounts.length - 1);
      await _save(accounts);
      return LoginResult.created(account);
    }

    final account = accounts[index];
    final passwordIsValid = await verifyPassword(
      password,
      account.storedPasswordHash,
    );
    // Strictly before anything is unlinked or written: a wrong password must
    // still leave this device exactly where it was, on whatever account it
    // was already acting for.
    if (!passwordIsValid) return const LoginResult.wrongPassword();

    // Its return value (whether this login moved the device off another
    // account) used to decide whether a write was needed at all. Every
    // branch below now writes unconditionally, because each one stamps
    // [DeviceLink.lastLoginAt], so there is nothing left to decide.
    _unlinkFromOtherAccounts(accounts, nodeId, keep: index);

    final existingIndex = account.devices.indexWhere(
      (device) => device.nodeId == nodeId,
    );
    if (existingIndex != -1) {
      final existing = account.devices[existingIndex];
      // Still idempotent in the sense that matters -- no second device row,
      // and [DeviceLink.linkedAt] keeps its original value, so re-logging in
      // never reshuffles a friend's reachability preference order
      // (`Friend.devicesByPreference`). What a re-login *does* refresh is
      // [DeviceLink.relayUrl] and [DeviceLink.deviceName]; if neither has
      // changed, nothing is written at all -- unless this login moved the
      // device off another account, which is a change to somebody's file
      // either way.
      // Every login now stamps [DeviceLink.lastLoginAt], so the
      // "nothing changed, write nothing" shortcut that used to live here is
      // gone on purpose: recency is the only thing that reliably tells two
      // same-platform devices apart in the device list, and a value only
      // written when something *else* changed would be exactly as useless
      // as `linkedAt` already is. Logins are rare enough (once per device,
      // then hardly ever) that one file write each is not a cost worth
      // optimizing against that.
      final devices = [...account.devices];
      devices[existingIndex] = DeviceLink(
        nodeId: existing.nodeId,
        publicKeyBase64: existing.publicKeyBase64,
        linkedAt: existing.linkedAt,
        relayUrl: relayUrl,
        deviceName: deviceName,
        lastLoginAt: now,
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
          deviceName: deviceName,
          lastLoginAt: now,
        ),
      ],
    );
    accounts[index] = updated;
    await _save(accounts);
    return LoginResult.linked(updated);
  }

  /// Drops [nodeId] from every account in [accounts] except the one at
  /// [keep], in place. Returns whether anything actually changed, which is
  /// what tells the caller it now has to save even on an otherwise
  /// no-op login.
  ///
  /// Only ever called with the target account's password already verified
  /// (or the account being created right now by that same device), so this
  /// can never be used to knock somebody else's device off their account.
  /// Rewrites device lists only -- no account is ever deleted, so the
  /// indices [_loginOrSignupLocked] is holding stay valid, and an account
  /// left with no devices is simply one nobody is currently signed in on: its
  /// password still works and re-links a device on the next login.
  bool _unlinkFromOtherAccounts(
    List<Account> accounts,
    String nodeId, {
    required int keep,
  }) {
    var changed = false;
    for (var i = 0; i < accounts.length; i++) {
      if (i == keep) continue;
      final account = accounts[i];
      if (!account.devices.any((device) => device.nodeId == nodeId)) continue;
      accounts[i] = account.copyWith(
        devices: account.devices
            .where((device) => device.nodeId != nodeId)
            .toList(),
      );
      changed = true;
    }
    return changed;
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
