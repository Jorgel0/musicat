import 'dart:convert';

import 'password_hashing.dart';

/// One device linked to an [Account] -- proven, at link time, to control
/// [nodeId]'s Ed25519 private key via the same self-certifying identity
/// check used everywhere else in this codebase ([nodeId] is the hex
/// SHA-256 fingerprint of [publicKeyBase64]'s raw bytes; see
/// `identity/node_identity.dart` and `relay/relay_hub.dart`).
/// [publicKeyBase64] is stored here, on the device itself, rather than
/// looked up from some other store, so every account route that needs to
/// verify a signed request from one of this account's own devices
/// (`account_request_auth.dart`) never needs a second store to do it.
class DeviceLink {
  const DeviceLink({
    required this.nodeId,
    required this.publicKeyBase64,
    required this.linkedAt,
    this.relayUrl,
  });

  final String nodeId;
  final String publicKeyBase64;
  final DateTime linkedAt;

  /// This device's own relay WebSocket endpoint (e.g.
  /// `ws://relay.example.com:8090/connect`) as it reported at its last
  /// login, or `null` if it has no relay configured -- **the only piece of
  /// reachability this service records about a device**, and the one that
  /// makes an account-only friendship usable at all.
  ///
  /// Without it, two people who become friends purely through this service
  /// have zero candidates for each other: each can *verify* the other's
  /// signed requests, neither can *initiate* one (see ADR 0050, which named
  /// the gap, and `federation/friend_reachability.dart`, which turns this
  /// into `<relay http origin>/<nodeId>/<path>` -- the ADR 0033 mechanism
  /// already proven across real networks). No address and no UDP candidate
  /// are recorded here, deliberately: those are learned by pairing with a
  /// specific device on a specific network and are nobody else's business,
  /// whereas a relay endpoint is a public host that already forwards to this
  /// nodeId for anyone who asks.
  ///
  /// **Privacy: this discloses which relay you use to your mutual friends**
  /// -- they are the only callers `GET /<accountId>/devices` and
  /// `GET /<me>/friends` ever answer with a device list. That is not a new
  /// disclosure (`relayUrl` is already exchanged at pairing time today, see
  /// `POST /api/v1/federation/friends`), but it is a deliberate choice
  /// rather than an accident: a friend learning "Jorge relays through
  /// relay.example.com" is the price of being reachable through it at all.
  ///
  /// Refreshed on every login (see [AccountStore.loginOrSignup]), including
  /// back to `null` for a device that no longer has a relay -- a stale entry
  /// would only send friends to a relay this device is no longer connected
  /// to, which costs them a wasted `502` per attempt.
  final String? relayUrl;

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'publicKeyBase64': publicKeyBase64,
    'linkedAt': linkedAt.toIso8601String(),
    'relayUrl': relayUrl,
  };

  /// Reads either shape: a row written by this version, or one written
  /// before [relayUrl] existed (every `accounts.json` on disk today), which
  /// simply has no such key and loads with a `null` relay -- the same
  /// nullable-field-defaulting pattern `Friend.fromJson` already relies on.
  factory DeviceLink.fromJson(Map<String, dynamic> json) => DeviceLink(
    nodeId: json['nodeId'] as String,
    publicKeyBase64: json['publicKeyBase64'] as String,
    linkedAt: DateTime.parse(json['linkedAt'] as String),
    relayUrl: json['relayUrl'] as String?,
  );
}

/// A portable, password-based account (Fase 5) -- distinct from, and not
/// yet consumed by, the lighter-weight device-pinned username directory
/// `relay/username_directory_store.dart` already has (see
/// `docs/adr/0045-username-directory.md`); that one is untouched and keeps
/// serving its own existing QR/paste-link "add a friend" flow.
///
/// [passwordHash]/[passwordSalt]/[argon2Params] are this account's most
/// sensitive persisted fields (see `password_hashing.dart`) -- never sent
/// back out over the API. Every account route in `account_routes.dart`
/// that returns an [Account] to a caller does so through a hand-built JSON
/// map that only ever includes [accountId]/[username]/[devices], never
/// through [toJson] (that method is only ever used by [AccountStore] to
/// persist to `accounts.json`).
class Account {
  const Account({
    required this.accountId,
    required this.username,
    required this.passwordHash,
    required this.passwordSalt,
    required this.argon2Params,
    required this.devices,
    required this.createdAt,
  });

  final String accountId;
  final String username;
  final List<int> passwordHash;
  final List<int> passwordSalt;
  final Argon2Params argon2Params;
  final List<DeviceLink> devices;
  final DateTime createdAt;

  PasswordHash get storedPasswordHash => PasswordHash(
    hash: passwordHash,
    salt: passwordSalt,
    params: argon2Params,
  );

  Account copyWith({List<DeviceLink>? devices}) => Account(
    accountId: accountId,
    username: username,
    passwordHash: passwordHash,
    passwordSalt: passwordSalt,
    argon2Params: argon2Params,
    devices: devices ?? this.devices,
    createdAt: createdAt,
  );

  /// The full persisted representation, including the password hash/salt
  /// -- only ever written to `accounts.json` by [AccountStore]. See this
  /// class's own doc comment for why routes never send this back out.
  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'username': username,
    'passwordHashBase64': base64Encode(passwordHash),
    'passwordSaltBase64': base64Encode(passwordSalt),
    'argon2Params': argon2Params.toJson(),
    'devices': [for (final device in devices) device.toJson()],
    'createdAt': createdAt.toIso8601String(),
  };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
    accountId: json['accountId'] as String,
    username: json['username'] as String,
    passwordHash: base64Decode(json['passwordHashBase64'] as String),
    passwordSalt: base64Decode(json['passwordSaltBase64'] as String),
    argon2Params: Argon2Params.fromJson(
      json['argon2Params'] as Map<String, dynamic>,
    ),
    devices: [
      for (final device in json['devices'] as List<dynamic>)
        DeviceLink.fromJson(device as Map<String, dynamic>),
    ],
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// One entry of `GET /accounts/<me>/friends` (ADR 0048's friend-request data
/// model, projected into "who am I actually friends with"): an account this
/// caller has an *accepted* friend request with, in either direction, plus
/// that account's current [devices].
///
/// The device list is inlined here rather than left to a follow-up
/// `GET /accounts/<accountId>/devices` per friend purely to save one signed
/// round trip each -- it is the exact same data, disclosed to the exact same
/// callers: that route's gate is "the caller is this account, or the two are
/// mutual friends", and every entry in this response is by construction a
/// mutual friend of the caller. Both gates read the same
/// [FriendRequestStore.areMutualFriends] rule.
///
/// Deliberately *not* an [Account]: this is the outward-facing projection,
/// and it has no field that could ever carry a password hash.
class AccountFriend {
  const AccountFriend({
    required this.accountId,
    required this.username,
    required this.devices,
  });

  final String accountId;
  final String username;
  final List<DeviceLink> devices;

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'username': username,
    'devices': [for (final device in devices) device.toJson()],
  };

  factory AccountFriend.fromJson(Map<String, dynamic> json) => AccountFriend(
    accountId: json['accountId'] as String,
    username: json['username'] as String,
    devices: [
      for (final device in json['devices'] as List<dynamic>)
        DeviceLink.fromJson(device as Map<String, dynamic>),
    ],
  );
}

/// One entry of `GET /accounts/<me>/friend-requests`: a [FriendRequest] with
/// **both sides' usernames resolved**, which is the whole reason this
/// projection exists.
///
/// A [FriendRequest] on its own carries only accountIds, and an accountId is
/// a 32-hex-character random string -- an app cannot show that to a human
/// and ask "do you want to be friends with this?". Resolving the username
/// here, on the service that already holds both accounts, costs one file
/// read per response; resolving it node-side would cost the node one
/// authenticated round trip per pending request, for data this service could
/// simply have included.
///
/// Discloses nothing new: this shape is only ever returned by
/// `GET /<me>/friend-requests`, which lists exactly the requests addressed
/// *to* the authenticated caller, plus the send/accept/decline responses for
/// a request that caller is one side of. Knowing who sent you a friend
/// request is the point of being told about it at all.
///
/// Deliberately *not* a [FriendRequest]: that class is the persisted record
/// (`friend_request_store.dart`), this one is the wire shape, and keeping
/// them separate is what stops a later field on the record from leaking out
/// of the API by default.
class AccountFriendRequest {
  const AccountFriendRequest({
    required this.id,
    required this.fromAccountId,
    required this.toAccountId,
    required this.status,
    required this.createdAt,
    this.fromUsername,
    this.toUsername,
  });

  final String id;
  final String fromAccountId;
  final String toAccountId;

  /// [fromAccountId]/[toAccountId]'s current usernames, or `null` in the
  /// (unreachable in practice -- accounts are never deleted) case of a
  /// request naming an account that no longer exists. Nullable rather than
  /// defaulted to some placeholder so a caller can tell "this person is
  /// called X" from "this service could not say", and never renders a
  /// made-up name.
  final String? fromUsername;
  final String? toUsername;

  /// `pending`/`accepted`/`declined`, as [FriendRequestStatus.name].
  final String status;

  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromAccountId': fromAccountId,
    'fromUsername': fromUsername,
    'toAccountId': toAccountId,
    'toUsername': toUsername,
    'status': status,
    'createdAt': createdAt.toIso8601String(),
  };

  /// Tolerates a response written before the username fields existed (they
  /// simply read back as `null`), so a node talking to an older account
  /// service still parses its friend requests rather than failing the whole
  /// list.
  factory AccountFriendRequest.fromJson(Map<String, dynamic> json) =>
      AccountFriendRequest(
        id: json['id'] as String,
        fromAccountId: json['fromAccountId'] as String,
        fromUsername: json['fromUsername'] as String?,
        toAccountId: json['toAccountId'] as String,
        toUsername: json['toUsername'] as String?,
        status: json['status'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
