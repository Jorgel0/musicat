import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'friend.dart';
import 'friend_store.dart';
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
/// `POST /friends` (register a friend by nodeId/public key/address) is
/// deliberately **not** behind signature verification yet — there's no
/// existing trust relationship to check it against. It's also not yet
/// gated by anything else (no pairing code, no local-only restriction),
/// which is a known, explicit gap — see ADR 0019's Consequences.
///
/// `GET /ping` **is** behind [RequestVerifier.verify]: it's the proof that
/// the signing/verification trust model actually works end to end before
/// any real federation feature is built on top of it.
Router buildFederationRouter(
  FriendStore friendStore,
  RequestVerifier verifier,
) {
  final router = Router();

  router.post('/friends', (Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final nodeId = body['nodeId'];
    final publicKeyBase64 = body['publicKeyBase64'];
    final address = body['address'];
    if (nodeId is! String || nodeId.isEmpty) {
      return _error('"nodeId" is required');
    }
    if (publicKeyBase64 is! String || publicKeyBase64.isEmpty) {
      return _error('"publicKeyBase64" is required');
    }
    if (address is! String || address.isEmpty) {
      return _error('"address" is required');
    }

    await friendStore.add(
      Friend(
        nodeId: nodeId,
        publicKeyBase64: publicKeyBase64,
        address: address,
        displayName: body['displayName'] as String?,
      ),
    );
    return _json({'status': 'ok'}, status: 201);
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
