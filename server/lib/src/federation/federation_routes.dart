import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../http/require_local.dart';
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
/// `POST /friends` must also stay reachable over the real network — it's
/// what a friend's server calls directly to redeem a code — so, unlike the
/// routes below, it is **not** wrapped in [requireLocal].
///
/// `GET /ping` **is** behind [RequestVerifier.verify]: it's the proof that
/// the signing/verification trust model actually works end to end before
/// any real federation feature is built on top of it.
///
/// `POST /pairing-codes`, `GET /friends`, `DELETE /friends/<nodeId>`,
/// `PATCH /friends/<nodeId>`, and `GET /friends/<nodeId>/status` are all
/// app-facing — meant only for this device's own app talking to its own
/// local server, never for a friend's server — and are wrapped in
/// [requireLocal] (see its own doc comment for the full rationale and the
/// relay-tunnel edge case it also covers). Before this, none of them
/// checked anything beyond "can this caller reach the server at all",
/// which is exactly the gap that made a stranger minting themselves a
/// pairing code and immediately self-registering as a friend possible with
/// zero involvement from this device's real owner.
///
/// `POST /friends` also accepts an optional `udpCandidate` (the caller's
/// own STUN-discovered address, ADR 0022) and returns this node's current
/// one in the response — and, when a candidate was provided, immediately
/// attempts a NAT hole-punch and starts maintaining it with keepalives in
/// the background (ADR 0023/0024). `GET /friends/<nodeId>/status` reports
/// whether that connection is currently alive; revoking a friend
/// (`DELETE`) also stops maintaining it.
///
/// It also accepts an optional `relayUrl` (the caller's own relay, ADR
/// 0032/0033 — only present if that caller is actually connected to one)
/// and returns this node's own in the response the same way, so a friend
/// unreachable via [Friend.address] can still be reached as a fallback
/// through whichever relay they reported.
///
/// `PATCH /friends/<nodeId>` sets [Friend.localNickname] — a purely local
/// label this device's own user picks for a friend, distinct from
/// [Friend.displayName] (what the friend calls *themselves*). Like `GET`/
/// `DELETE /friends/<nodeId>`, this is called by this device's own app,
/// not by another federation peer, so it isn't behind [RequestVerifier]
/// either.
///
/// [appApiKey] is forwarded to every [requireLocal] call below unchanged --
/// see that function's own doc comment for what it does. `null`/empty (the
/// default) reproduces the exact loopback-only behavior from before this
/// parameter existed.
Router buildFederationRouter(
  FriendStore friendStore,
  RequestVerifier verifier,
  PairingCodeStore pairingCodes,
  UdpPuncher puncher, {
  String? myRelayUrl,
  String? appApiKey,
}) {
  final router = Router();

  router.post(
    '/pairing-codes',
    requireLocal((Request request) async {
      return _json({'code': pairingCodes.generate()}, status: 201);
    }, appApiKey: appApiKey),
  );

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
    final relayUrl = body['relayUrl'];
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
    if (relayUrl != null && relayUrl is! String) {
      return _error('"relayUrl" must be a string if present');
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
        relayUrl: relayUrl as String?,
      ),
    );

    if (udpCandidate != null) {
      final parts = udpCandidate.split(':');
      if (parts.length == 2) {
        final targetPort = int.tryParse(parts[1]);
        if (targetPort != null) {
          unawaited(
            puncher.punchAndMaintain(
              nodeId: nodeId,
              host: parts[0],
              port: targetPort,
            ),
          );
        }
      }
    }

    return _json({
      'status': 'ok',
      'udpCandidate': puncher.cachedCandidate?.toString(),
      'relayUrl': myRelayUrl,
    }, status: 201);
  });

  router.get(
    '/friends',
    requireLocal((Request request) async {
      final friends = await friendStore.loadAll();
      return _json([for (final friend in friends) friend.toJson()]);
    }, appApiKey: appApiKey),
  );

  router.delete(
    '/friends/<nodeId>',
    requireLocal((Request request) async {
      final nodeId = request.params['nodeId']!;
      await friendStore.remove(nodeId);
      puncher.stopKeepalive(nodeId);
      return Response(204);
    }, appApiKey: appApiKey),
  );

  router.patch(
    '/friends/<nodeId>',
    requireLocal((Request request) async {
      final nodeId = request.params['nodeId']!;
      final Map<String, dynamic> body;
      try {
        final raw = await request.readAsString();
        body = raw.isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        return _error('Request body must be JSON');
      }

      final localNickname = body['localNickname'];
      if (localNickname != null && localNickname is! String) {
        return _error('"localNickname" must be a string if present');
      }

      final updated = await friendStore.setLocalNickname(
        nodeId,
        localNickname as String?,
      );
      if (updated == null) {
        return _error('Unknown friend', status: 404);
      }
      return _json(updated.toJson());
    }, appApiKey: appApiKey),
  );

  router.get(
    '/friends/<nodeId>/status',
    requireLocal((Request request) async {
      final nodeId = request.params['nodeId']!;
      final lastSeen = puncher.lastSeen(nodeId);
      return _json({
        'connected': puncher.isConnected(nodeId),
        'lastSeen': lastSeen?.toIso8601String(),
      });
    }, appApiKey: appApiKey),
  );

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
