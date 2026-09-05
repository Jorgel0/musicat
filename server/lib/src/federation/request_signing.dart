import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';

import '../identity/node_identity.dart';
import 'friend.dart';
import 'friend_store.dart';
import 'unknown_device_resolver.dart';

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

/// The outcome of [RequestVerifier.verify].
///
/// [friendAccountId] is the whole point of this being a value rather than a
/// bare enum: it is the identity every downstream authorization check must
/// use ([friendAccountId], never [deviceNodeId] — a friend's *account* is
/// what a track is shared with, not one of their phones). Both are non-null
/// exactly when [result] is [RequestVerificationResult.valid].
class RequestVerification {
  const RequestVerification._(
    this.result, {
    this.friendAccountId,
    this.deviceNodeId,
  });

  const RequestVerification.valid({
    required String friendAccountId,
    required String deviceNodeId,
  }) : this._(
         RequestVerificationResult.valid,
         friendAccountId: friendAccountId,
         deviceNodeId: deviceNodeId,
       );

  const RequestVerification.failed(RequestVerificationResult result)
    : this._(result);

  final RequestVerificationResult result;

  /// The verified caller's friend *account* id — for a legacy
  /// device-pinned friend this is identical to [deviceNodeId], which is
  /// exactly why switching every authorization check over to it preserves
  /// existing behavior byte for byte.
  final String? friendAccountId;

  /// Which of that account's devices actually signed the request.
  final String? deviceNodeId;

  bool get isValid => result == RequestVerificationResult.valid;
}

/// Verifies incoming federation requests against a known friend account's
/// device keys — the object-level authorization check every federation
/// endpoint must go through: a request is only trusted if its claimed
/// `nodeId` is currently one of a friend account's devices *and* the
/// signature proves it, never just because it arrived with node-id-shaped
/// headers.
///
/// **The hot path is deliberately offline.** [friendStore] is local disk
/// and nothing else, so an established friend's request verifies with the
/// account service (and the whole internet) unreachable. The optional
/// [unknownDeviceResolver] is the single, narrow exception: when a nodeId
/// matches *no* known friend's cached device set — the case that used to be
/// a flat rejection — it gets one rate-limited chance to learn that the
/// nodeId is a newly-linked device of a friend this node already trusts,
/// after which the local lookup is retried exactly once. Left `null` (the
/// default, and what `UdpPuncher` uses), this class cannot make a network
/// call at all.
///
/// Even that exception sits behind the free, purely-local checks: the
/// timestamp/clock-skew check runs first, so a request that could never
/// have verified anyway costs nothing at all — see [verify].
class RequestVerifier {
  RequestVerifier(this.friendStore, {this.unknownDeviceResolver});

  final FriendStore friendStore;

  /// See [UnknownDeviceResolver] — `null` means "never look anything up",
  /// which is a fully supported configuration, not a degraded one.
  final UnknownDeviceResolver? unknownDeviceResolver;

  static final _algorithm = Ed25519();
  static const _maxClockSkew = Duration(minutes: 5);

  Future<RequestVerification> verify({
    required String method,
    required String path,
    required String body,
    required String? nodeId,
    required String? timestamp,
    required String? signatureBase64,
  }) async {
    if (nodeId == null || timestamp == null || signatureBase64 == null) {
      return const RequestVerification.failed(
        RequestVerificationResult.invalidSignature,
      );
    }

    // The timestamp is checked before anything else that could cost
    // something, and deliberately *before* the cache-miss resolver below.
    // It is a pure, local, string-shaped check, and the request is still
    // entirely unauthenticated at this point: letting a caller past it
    // would let anyone spend one of this node's rate-limited account
    // lookups -- and several seconds of its own wall clock, waiting on a
    // possibly-unreachable account service -- with a made-up nodeId and a
    // garbage signature. That also starves the budget legitimate
    // new-device learning depends on. The consequence is that an unknown
    // nodeId sent with a stale timestamp now reports [staleTimestamp]
    // rather than [unknownNode]; both were, and remain, rejections.
    final requestTime = DateTime.tryParse(timestamp);
    if (requestTime == null ||
        DateTime.now().toUtc().difference(requestTime).abs() > _maxClockSkew) {
      return const RequestVerification.failed(
        RequestVerificationResult.staleTimestamp,
      );
    }

    var match = await _findDevice(nodeId);
    if (match == null) {
      final resolver = unknownDeviceResolver;
      if (resolver == null) {
        return const RequestVerification.failed(
          RequestVerificationResult.unknownNode,
        );
      }
      // Cache miss: this may be a device a friend linked to their account
      // after this node last heard about them. One rate-limited lookup,
      // then exactly one retry -- never a loop, and never anything the
      // successful path above touches.
      final learned = await resolver.resolveUnknownDevice(nodeId);
      match = learned ? await _findDevice(nodeId) : null;
      if (match == null) {
        return const RequestVerification.failed(
          RequestVerificationResult.unknownNode,
        );
      }
    }

    final message = canonicalRequestString(
      method: method,
      path: path,
      timestamp: timestamp,
      body: body,
    );
    final publicKey = SimplePublicKey(
      base64Decode(match.device.publicKeyBase64),
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
        ? RequestVerification.valid(
            friendAccountId: match.friend.accountId,
            deviceNodeId: nodeId,
          )
        : const RequestVerification.failed(
            RequestVerificationResult.invalidSignature,
          );
  }

  Future<({Friend friend, FriendDevice device})?> _findDevice(
    String nodeId,
  ) async {
    final friend = await friendStore.findByDeviceNodeId(nodeId);
    final device = friend?.deviceFor(nodeId);
    if (friend == null || device == null) return null;
    return (friend: friend, device: device);
  }
}

/// Verifies [request]'s `X-Node-Id`/`X-Timestamp`/`X-Signature` headers
/// against [verifier], returning the caller's verified friend **account
/// id** if valid or `null` otherwise. Every federation route that requires
/// a known, signed caller (not just `/ping` — see `sharing_routes.dart`)
/// goes through this same check, so "is this a real, trusted friend" is
/// answered identically everywhere rather than re-implemented per route.
///
/// Returns the account id rather than the signing device's nodeId on
/// purpose: authorization is per friend account (a track shared with a
/// friend is shared with that friend, not with one of their phones). For a
/// legacy device-pinned friend the two values are identical, so existing
/// behavior is unchanged.
Future<String?> verifiedFriendAccountId(
  Request request,
  RequestVerifier verifier,
) async {
  final verification = await verifier.verify(
    method: request.method,
    path: request.requestedUri.path,
    body: '',
    nodeId: request.headers['x-node-id'],
    timestamp: request.headers['x-timestamp'],
    signatureBase64: request.headers['x-signature'],
  );
  return verification.friendAccountId;
}
