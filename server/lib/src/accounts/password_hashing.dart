import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// The Argon2id cost parameters a particular [Account] (see `account.dart`)
/// was hashed with -- stored alongside its hash/salt rather than assumed
/// from a single global constant, so [recommended] can be raised later for
/// *new* accounts without invalidating ones already hashed under a lower
/// cost: [verifyPassword] always re-derives with whichever [Argon2Params]
/// the account itself was actually hashed with, never a currently-configured
/// default.
class Argon2Params {
  const Argon2Params({
    required this.memory,
    required this.iterations,
    required this.parallelism,
  });

  /// OWASP's Password Storage Cheat Sheet lists several defensible
  /// Argon2id configurations; this is its second one: m=19456 KiB (19
  /// MiB), t=2 iterations, p=1 lane. Chosen over its first option (m=47104,
  /// t=1) because this is a small, self-hosted relay with no guarantee of
  /// 46+ MiB free per concurrent login attempt, and t=2 (vs t=1) keeps some
  /// margin against attacks that specialize in raising memory-hardness
  /// while holding iterations at the legal minimum. Benchmarked directly
  /// against `package:cryptography`'s actual (pure-Dart, no native
  /// bindings) [Argon2id] implementation at ~200ms per hash on ordinary
  /// hardware -- comfortably fast enough for an interactive login request,
  /// not so slow it becomes its own denial-of-service surface.
  static const recommended = Argon2Params(
    memory: 19456,
    iterations: 2,
    parallelism: 1,
  );

  /// Number of 1 KiB memory blocks.
  final int memory;
  final int iterations;
  final int parallelism;

  Map<String, dynamic> toJson() => {
    'memory': memory,
    'iterations': iterations,
    'parallelism': parallelism,
  };

  factory Argon2Params.fromJson(Map<String, dynamic> json) => Argon2Params(
    memory: json['memory'] as int,
    iterations: json['iterations'] as int,
    parallelism: json['parallelism'] as int,
  );
}

/// Both the raw output length of every hash [hashPassword] produces and
/// what it asks [Argon2id] to derive -- comfortably within this package's
/// own documented range ("at least 16 bytes... more than 32 is
/// unnecessary").
const _hashLength = 32;

/// Length of the random per-account salt [hashPassword] generates.
const _saltLength = 16;

/// The result of [hashPassword]: the derived key bytes, the random salt
/// used to derive them, and the exact [Argon2Params] used -- everything an
/// [Account] persists (`account.dart`) and everything [verifyPassword]
/// needs to check a later attempt against.
class PasswordHash {
  const PasswordHash({
    required this.hash,
    required this.salt,
    required this.params,
  });

  final List<int> hash;
  final List<int> salt;
  final Argon2Params params;
}

/// Hashes [password] with a fresh random salt (`Random.secure()`, the same
/// convention as `PairingCodeStore`/relay nonces) under [params] --
/// called exactly once, at account creation.
Future<PasswordHash> hashPassword(
  String password, {
  Argon2Params params = Argon2Params.recommended,
}) async {
  final salt = List<int>.generate(
    _saltLength,
    (_) => Random.secure().nextInt(256),
  );
  final hash = await _derive(password, salt, params);
  return PasswordHash(hash: hash, salt: salt, params: params);
}

/// Re-derives [password] with [stored]'s own salt and params (never a
/// currently-configured default -- see [Argon2Params]'s own doc comment)
/// and compares the result against [stored]'s hash in constant time (both
/// sides are always exactly [_hashLength] bytes, so there is no
/// length-driven early exit either) -- never a plain `==`, which would leak
/// how many leading bytes matched through response timing.
Future<bool> verifyPassword(String password, PasswordHash stored) async {
  final candidate = await _derive(password, stored.salt, stored.params);
  return _constantTimeBytesEqual(candidate, stored.hash);
}

Future<List<int>> _derive(
  String password,
  List<int> salt,
  Argon2Params params,
) async {
  final algorithm = Argon2id(
    parallelism: params.parallelism,
    memory: params.memory,
    iterations: params.iterations,
    hashLength: _hashLength,
  );
  final key = await algorithm.deriveKeyFromPassword(
    password: password,
    nonce: salt,
  );
  return key.extractBytes();
}

bool _constantTimeBytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
