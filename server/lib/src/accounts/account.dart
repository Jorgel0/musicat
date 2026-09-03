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
  });

  final String nodeId;
  final String publicKeyBase64;
  final DateTime linkedAt;

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'publicKeyBase64': publicKeyBase64,
    'linkedAt': linkedAt.toIso8601String(),
  };

  factory DeviceLink.fromJson(Map<String, dynamic> json) => DeviceLink(
    nodeId: json['nodeId'] as String,
    publicKeyBase64: json['publicKeyBase64'] as String,
    linkedAt: DateTime.parse(json['linkedAt'] as String),
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
