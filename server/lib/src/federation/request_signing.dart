import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';

import '../identity/node_identity.dart';
import 'friend_store.dart';

/// The exact bytes a node signs (and a verifier reconstructs) to prove a
/// federation request came from it. Binding the method, full request path,
/// a timestamp, and the body means a captured signature can't be replayed
/// against a different request, and [RequestVerifier]'s timestamp check
/// bounds how long a captured one stays usable at all.
String canonicalRequestString({
  required String method,
  required String path,
  required String timestamp,
  required String body,
}) => '$method\n$path\n$timestamp\n$body';

/// Signs outgoing federation requests with this node's own private key.
class RequestSigner {
  RequestSigner(this.identity);

  final NodeIdentity identity;

  /// Headers to attach to a request this node is about to send.
  Future<Map<String, String>> sign({
    required String method,
    required String path,
    String body = '',
  }) async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final message = canonicalRequestString(
      method: method,
      path: path,
      timestamp: timestamp,
      body: body,
    );
    final signatureBytes = await identity.sign(utf8.encode(message));
    return {
      'X-Node-Id': identity.nodeId,
      'X-Timestamp': timestamp,
      'X-Signature': base64Encode(signatureBytes),
    };
  }
}

enum RequestVerificationResult {
  valid,
  unknownNode,
  staleTimestamp,
  invalidSignature,
}

/// Verifies incoming federation requests against a known [Friend]'s public
/// key — the object-level authorization check every federation endpoint
/// must go through: a request is only trusted if its claimed `nodeId` is
/// actually a friend *and* the signature proves it, never just because it
/// arrived with node-id-shaped headers.
class RequestVerifier {
  RequestVerifier(this.friendStore);

  final FriendStore friendStore;

  static final _algorithm = Ed25519();
  static const _maxClockSkew = Duration(minutes: 5);

  Future<RequestVerificationResult> verify({
    required String method,
    required String path,
    required String body,
    required String? nodeId,
    required String? timestamp,
    required String? signatureBase64,
  }) async {
    if (nodeId == null || timestamp == null || signatureBase64 == null) {
      return RequestVerificationResult.invalidSignature;
    }

    final friend = await friendStore.findByNodeId(nodeId);
    if (friend == null) return RequestVerificationResult.unknownNode;

    final requestTime = DateTime.tryParse(timestamp);
    if (requestTime == null ||
        DateTime.now().toUtc().difference(requestTime).abs() > _maxClockSkew) {
      return RequestVerificationResult.staleTimestamp;
    }

    final message = canonicalRequestString(
      method: method,
      path: path,
      timestamp: timestamp,
      body: body,
    );
    final publicKey = SimplePublicKey(
      base64Decode(friend.publicKeyBase64),
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
        ? RequestVerificationResult.valid
        : RequestVerificationResult.invalidSignature;
  }
}

/// Verifies [request]'s `X-Node-Id`/`X-Timestamp`/`X-Signature` headers
/// against [verifier], returning the caller's `nodeId` if valid or `null`
/// otherwise. Every federation route that requires a known, signed caller
/// (not just `/ping` — see `sharing_routes.dart`) goes through this same
/// check, so "is this a real, trusted friend" is answered identically
/// everywhere rather than re-implemented per route.
Future<String?> verifiedNodeId(
  Request request,
  RequestVerifier verifier,
) async {
  final nodeId = request.headers['x-node-id'];
  final result = await verifier.verify(
    method: request.method,
    path: request.requestedUri.path,
    body: '',
    nodeId: nodeId,
    timestamp: request.headers['x-timestamp'],
    signatureBase64: request.headers['x-signature'],
  );
  return result == RequestVerificationResult.valid ? nodeId : null;
}
