import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../nat/udp_puncher.dart';
import 'friend.dart';
import 'friend_store.dart';
import 'pairing_code_store.dart';
import 'request_signing.dart';

Response _json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Response _error(String message, {int status = 400}) =>
    _json({'error': message}, status: status);

Response _verificationErrorResponse(
  RequestVerificationResult result,
) => switch (result) {
  RequestVerificationResult.unknownNode => _error('Unknown node', status: 403),
  RequestVerificationResult.staleTimestamp => _error(
    'Missing or stale timestamp',
    status: 401,
  ),
  RequestVerificationResult.invalidSignature => _error(
    'Invalid signature',
    status: 401,
  ),
  RequestVerificationResult.valid => throw StateError('valid is not an error'),
};

/// Builds the `/api/v1/federation/*` routes.
///
/// `POST /friends` (register a friend by nodeId/public key/address) requires
/// a currently-valid, single-use code from `POST /pairing-codes` — this is
/// the out-of-band trust bootstrap (a code shared via QR/link) that closes
/// the gap ADR 0019 flagged (friend registration previously had no
/// protection at all). Neither of these two routes sits behind
/// [RequestVerifier]: there's no existing trust relationship yet for
/// `/friends` to check against, and `/pairing-codes` is what a node offers
/// to someone *becoming* a friend, so it can't require already being one.
///
/// `GET /ping` **is** behind [RequestVerifier.verify]: it's the proof that
/// the signing/verification trust model actually works end to end before
/// any real federation feature is built on top of it.
///
/// `POST /friends` also accepts an optional `udpCandidate` (the caller's
/// own STUN-discovered address, ADR 0022) and returns this node's current
/// one in the response — and, when a candidate was provided, immediately
/// attempts a NAT hole-punch toward it in the background (ADR 0023).
Router buildFederationRouter(
  FriendStore friendStore,
  RequestVerifier verifier,
  PairingCodeStore pairingCodes,
  UdpPuncher puncher,
) {
  final router = Router();

  router.post('/pairing-codes', (Request request) async {
    return _json({'code': pairingCodes.generate()}, status: 201);
  });

  router.post('/friends', (Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final code = body['code'];
    final nodeId = body['nodeId'];
    final publicKeyBase64 = body['publicKeyBase64'];
    final address = body['address'];
    final udpCandidate = body['udpCandidate'];
    if (code is! String || code.isEmpty) {
      return _error('"code" is required');
    }
    if (nodeId is! String || nodeId.isEmpty) {
      return _error('"nodeId" is required');
    }
    if (publicKeyBase64 is! String || publicKeyBase64.isEmpty) {
      return _error('"publicKeyBase64" is required');
    }
    if (address is! String || address.isEmpty) {
      return _error('"address" is required');
    }
    if (udpCandidate != null && udpCandidate is! String) {
      return _error('"udpCandidate" must be a string if present');
    }

    if (!pairingCodes.redeem(code)) {
      return _error(
        'Invalid, expired, or already-used pairing code',
        status: 403,
      );
    }

    await friendStore.add(
      Friend(
        nodeId: nodeId,
        publicKeyBase64: publicKeyBase64,
        address: address,
        displayName: body['displayName'] as String?,
        udpCandidate: udpCandidate as String?,
      ),
    );

    if (udpCandidate != null) {
      final parts = udpCandidate.split(':');
      if (parts.length == 2) {
        final targetPort = int.tryParse(parts[1]);
        if (targetPort != null) {
          unawaited(puncher.punch(host: parts[0], port: targetPort));
        }
      }
    }

    return _json({
      'status': 'ok',
      'udpCandidate': puncher.cachedCandidate?.toString(),
    }, status: 201);
  });

  router.get('/friends', (Request request) async {
    final friends = await friendStore.loadAll();
    return _json([for (final friend in friends) friend.toJson()]);
  });

  router.delete('/friends/<nodeId>', (Request request, String nodeId) async {
    await friendStore.remove(nodeId);
    return Response(204);
  });

  router.get('/ping', (Request request) async {
    final result = await verifier.verify(
      method: request.method,
      path: request.requestedUri.path,
      body: '',
      nodeId: request.headers['x-node-id'],
      timestamp: request.headers['x-timestamp'],
      signatureBase64: request.headers['x-signature'],
    );
    if (result != RequestVerificationResult.valid) {
      return _verificationErrorResponse(result);
    }
    return _json({'pong': true});
  });

  return router;
}
