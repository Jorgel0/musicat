import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../federation/request_signing.dart' show canonicalRequestString;

enum AccountRequestVerificationResult {
  valid,
  staleTimestamp,
  invalidSignature,
}

/// Verifies a signed account-service request against an already-resolved
/// public key -- the exact same `X-Node-Id`/`X-Timestamp`/`X-Signature`
/// shape and canonical string (`canonicalRequestString`, reused directly
/// from `federation/request_signing.dart`) that `RequestVerifier` uses for
/// federation requests.
///
/// This is a separate, small verifier rather than `RequestVerifier` itself
/// because `RequestVerifier` resolves its caller's public key from
/// `FriendStore` (another node's *federation* trust), while every account
/// route needs to resolve one from an [Account]'s own linked device
/// instead (`AccountStore.findByDeviceNodeId`) -- a different, unrelated
/// source of truth for "whose key is this", even though the proof shape
/// itself (nonce-free, timestamp+signature over a canonical request
/// string) is identical on purpose. A later round is expected to unify the
/// two once the account service is the sole source of device identity --
/// see the brief this was built against.
class AccountRequestVerifier {
  static final _algorithm = Ed25519();

  /// Same bound as `RequestVerifier`'s own `_maxClockSkew`.
  static const maxClockSkew = Duration(minutes: 5);

  static Future<AccountRequestVerificationResult> verify({
    required String method,
    required String path,
    required String body,
    required String timestamp,
    required String signatureBase64,
    required String publicKeyBase64,
  }) async {
    final requestTime = DateTime.tryParse(timestamp);
    if (requestTime == null ||
        DateTime.now().toUtc().difference(requestTime).abs() > maxClockSkew) {
      return AccountRequestVerificationResult.staleTimestamp;
    }

    final message = canonicalRequestString(
      method: method,
      path: path,
      timestamp: timestamp,
      body: body,
    );
    final publicKey = SimplePublicKey(
      base64Decode(publicKeyBase64),
      type: KeyPairType.ed25519,
    );
    final signature = Signature(
      base64Decode(signatureBase64),
      publicKey: publicKey,
    );
    final isValid = await _algorithm.verify(
      utf8.encode(message),
      signature: signature,
    );
    return isValid
        ? AccountRequestVerificationResult.valid
        : AccountRequestVerificationResult.invalidSignature;
  }
}
