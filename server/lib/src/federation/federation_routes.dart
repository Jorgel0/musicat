import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../accounts/account_service_client.dart';
import '../http/require_local.dart';
import '../identity/node_identity.dart';
import '../nat/udp_puncher.dart';
import '../relay/relay_client.dart';
import '../relay/username_directory_store.dart';
import 'friend.dart';
import 'friend_reachability.dart';
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
/// `POST /friends` always checks that the `nodeId` it is handed really is
/// the SHA-256 fingerprint of the `publicKeyBase64` alongside it
/// ([nodeIdForPublicKey]), rejecting the pair with `400` otherwise — the
/// self-certifying-nodeId property is what makes every later signature
/// check mean anything, and this is the one place a nodeId/key pair enters
/// this node from the wire without one.
///
/// `POST /friends` also accepts an optional `accountId` — the caller
/// claiming "this device belongs to that portable account" (Fase 5, ADR
/// 0048). It is only ever believed if [accountService] is configured *and*
/// confirms it (`GET /accounts/by-device/<nodeId>` must return that exact
/// accountId): a claim that the account service actively contradicts is
/// rejected outright (`403`), and one it simply can't confirm right now
/// (no account service configured, or unreachable) is *ignored*, creating
/// an ordinary device-pinned friend instead — pairing on a local network
/// with the relay down has to keep working exactly as it always did. The
/// response's own `accountId` field reports which of the two happened.
/// Without this, a peer redeeming a pairing code could name someone else's
/// accountId and have this node adopt that account's whole device list as
/// trusted. A confirmed accountId that would displace an *existing*
/// device-pinned friend (someone else's, i.e. not the device currently
/// pairing) is refused with `403` rather than silently replacing them.
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
/// Every app-facing `/friends/<id>` route accepts either a friend's
/// `accountId` or any of their devices' nodeIds — an id stored by the app
/// before Fase 5 is always the latter, and for a device-pinned friend the
/// two are the same string anyway.
///
/// `DELETE /friends/<id>` is instant, local, and permanent: it also writes
/// a [FriendTombstone] (see `friend_store.dart`), so no later device-list
/// refresh can bring that friend back. Re-adding them explicitly (another
/// pairing) clears it.
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
///
/// `POST /username` and `GET /directory/lookup` are also app-facing
/// (wrapped in [requireLocal]): the first claims a username on [relayClient]'s
/// currently-connected relay (over the same authenticated tunnel, see
/// `RelayClaimUsername`'s doc comment -- never a new form of authentication,
/// just a friendly pointer to this node's own nodeId), returning `503` if
/// no relay is currently connected, `200` on success, `409` if the username
/// is already claimed by a different node, and `400` on an invalid format.
/// The second resolves a username against that same relay's own `GET
/// /directory/lookup` (a plain, unauthenticated HTTP call -- see
/// `relay_hub.dart`), forwarding its exact status code and body back
/// (`200` with `{"nodeId": ...}`, or `404`); `503` if no relay is currently
/// connected. [relayClient] is `null` exactly when `startMusicatServer` was
/// never given a relay to connect to at all.
Router buildFederationRouter(
  FriendStore friendStore,
  RequestVerifier verifier,
  PairingCodeStore pairingCodes,
  UdpPuncher puncher, {
  String? myRelayUrl,
  String? appApiKey,
  RelayClient? relayClient,
  http.Client? httpClient,
  AccountServiceClient? accountService,
}) {
  final client = httpClient ?? http.Client();
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
    final claimedAccountId = body['accountId'];
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
    if (claimedAccountId != null &&
        (claimedAccountId is! String || claimedAccountId.isEmpty)) {
      return _error('"accountId" must be a non-empty string if present');
    }

    // The caller says "I am <nodeId>, here is <publicKeyBase64>". A nodeId
    // is *defined* as the SHA-256 fingerprint of that key
    // ([nodeIdForPublicKey]), so the pair must be checked against each
    // other before either value is used for anything -- the same check
    // `relay_hub.dart` makes of a node connecting to a relay and
    // `account_routes.dart` of a device logging in. Without it, whoever
    // holds a pairing code can register *someone else's* nodeId against
    // *their own* key: this node would then store the attacker's key under
    // the victim's identity, and (with an accountId claimed alongside, see
    // below) the account service would happily confirm that the victim's
    // nodeId really does belong to the victim's account -- so the
    // attacker's signatures would verify as the victim's whole account.
    // Deliberately checked before the code is redeemed, so a malformed
    // request doesn't burn an otherwise-valid single-use code.
    final List<int> publicKeyBytes;
    try {
      publicKeyBytes = base64Decode(publicKeyBase64);
    } on FormatException {
      return _error('"publicKeyBase64" must be valid base64');
    }
    if (await nodeIdForPublicKey(publicKeyBytes) != nodeId) {
      return _error('"nodeId" is not the fingerprint of "publicKeyBase64"');
    }

    if (!pairingCodes.redeem(code)) {
      return _error(
        'Invalid, expired, or already-used pairing code',
        status: 403,
      );
    }

    // Only ever reached with a genuine, just-redeemed pairing code, so an
    // unauthenticated caller can't use this to make this node hammer the
    // account service.
    String? confirmedAccountId;
    if (claimedAccountId is String && accountService != null) {
      final resolved = await accountService.accountIdForDevice(nodeId);
      if (resolved != null && resolved != claimedAccountId) {
        return _error(
          '"accountId" is not the account this device belongs to',
          status: 403,
        );
      }
      confirmedAccountId = resolved;
    }

    if (confirmedAccountId != null) {
      // Defence in depth for Rule 2. `FriendStore.add` supersedes whatever
      // entry already holds this accountId, so an accountId that happens
      // to collide with an existing *device-pinned* friend's own nodeId
      // would silently delete that friend and hand the newcomer
      // everything shared with them. Real ids can't collide (an accountId
      // is 32 hex characters from `AccountStore`, a nodeId is a 64-hex
      // SHA-256 fingerprint), so this can only fire for a malicious or
      // compromised account service -- a trusted component, but the guard
      // is free, and losing an established friend is not a failure mode
      // worth leaving to someone else's correctness. A legacy friend
      // upgrading to *their own* account is unaffected: the colliding
      // entry is then that same device's, so the check passes and `add`
      // supersedes it as intended.
      final colliding = await friendStore.findByAccountId(confirmedAccountId);
      if (colliding != null &&
          colliding.isDevicePinned &&
          colliding.devices.single.nodeId != nodeId) {
        return _error(
          'That accountId already identifies a different friend on this '
          'device',
          status: 403,
        );
      }
    }

    final device = FriendDevice(
      nodeId: nodeId,
      publicKeyBase64: publicKeyBase64,
      address: address,
      udpCandidate: udpCandidate as String?,
      relayUrl: relayUrl as String?,
    );
    await friendStore.add(
      confirmedAccountId == null
          ? Friend.devicePinned(
              nodeId: nodeId,
              publicKeyBase64: publicKeyBase64,
              address: address,
              displayName: body['displayName'] as String?,
              udpCandidate: udpCandidate,
              relayUrl: relayUrl,
            )
          : Friend(
              accountId: confirmedAccountId,
              devices: [device],
              displayName: body['displayName'] as String?,
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
      // Which account, if any, this node actually recorded the caller
      // under -- null means "recorded as a device-pinned friend", whether
      // because none was claimed or because it couldn't be confirmed.
      'accountId': confirmedAccountId,
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
    '/friends/<friendId>',
    requireLocal((Request request) async {
      final friendId = request.params['friendId']!;
      final friend = await friendStore.findByAccountOrDeviceId(friendId);
      // Removal itself is local and unconditional -- it never waits on the
      // account service -- and leaves a tombstone behind so a later
      // refresh can't undo it (see FriendStore.remove).
      await friendStore.remove(friendId);
      for (final device in friend?.devices ?? const <FriendDevice>[]) {
        puncher.stopKeepalive(device.nodeId);
      }
      puncher.stopKeepalive(friendId);
      return Response(204);
    }, appApiKey: appApiKey),
  );

  router.patch(
    '/friends/<friendId>',
    requireLocal((Request request) async {
      final friendId = request.params['friendId']!;
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
        friendId,
        localNickname as String?,
      );
      if (updated == null) {
        return _error('Unknown friend', status: 404);
      }
      return _json(updated.toJson());
    }, appApiKey: appApiKey),
  );

  router.get(
    '/friends/<friendId>/status',
    requireLocal((Request request) async {
      final friendId = request.params['friendId']!;
      final friend = await friendStore.findByAccountOrDeviceId(friendId);
      // A friend account is "connected" if *any* of its devices' NAT
      // mappings is currently alive, and last seen whenever the most
      // recent of them was. An unknown id falls back to treating it as a
      // bare nodeId, exactly as this route always did.
      final nodeIds = friend == null
          ? [friendId]
          : [for (final device in friend.devices) device.nodeId];
      DateTime? lastSeen;
      for (final nodeId in nodeIds) {
        final seen = puncher.lastSeen(nodeId);
        if (seen != null && (lastSeen == null || seen.isAfter(lastSeen))) {
          lastSeen = seen;
        }
      }
      return _json({
        'connected': nodeIds.any(puncher.isConnected),
        'lastSeen': lastSeen?.toIso8601String(),
      });
    }, appApiKey: appApiKey),
  );

  router.post(
    '/username',
    requireLocal((Request request) async {
      if (relayClient == null || !relayClient.isConnected) {
        return _error(
          'No relay is currently connected to this node',
          status: 503,
        );
      }

      final Map<String, dynamic> body;
      try {
        body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      } on FormatException {
        return _error('Request body must be JSON');
      }

      final username = body['username'];
      if (username is! String || username.isEmpty) {
        return _error('"username" is required');
      }

      final result = await relayClient.claimUsername(username);
      if (result.success) {
        return _json({'username': username});
      }

      final status = switch (result.error) {
        usernameAlreadyTakenError => 409,
        invalidUsernameFormatError => 400,
        // Anything else is a relay-side/transport problem (not currently
        // connected after all, a claim already in flight, a timeout, ...)
        // rather than the claim itself being rejected on its merits.
        _ => 502,
      };
      return _error(result.error ?? 'Failed to claim username', status: status);
    }, appApiKey: appApiKey),
  );

  router.get(
    '/directory/lookup',
    requireLocal((Request request) async {
      final relayUrl = myRelayUrl;
      if (relayClient == null || !relayClient.isConnected || relayUrl == null) {
        return _error(
          'No relay is currently connected to this node',
          status: 503,
        );
      }

      final username = request.requestedUri.queryParameters['username'];
      if (username == null || username.isEmpty) {
        return _error('"username" query parameter is required');
      }

      final lookupUri = relayHttpOrigin(relayUrl).replace(
        path: '/directory/lookup',
        queryParameters: {'username': username},
      );

      final http.Response relayResponse;
      try {
        relayResponse = await client
            .get(lookupUri)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        return _error('Could not reach the relay', status: 502);
      }

      return Response(
        relayResponse.statusCode,
        body: relayResponse.body,
        headers: {'content-type': 'application/json'},
      );
    }, appApiKey: appApiKey),
  );

  router.get('/ping', (Request request) async {
    final verification = await verifier.verify(
      method: request.method,
      path: request.requestedUri.path,
      body: '',
      nodeId: request.headers['x-node-id'],
      timestamp: request.headers['x-timestamp'],
      signatureBase64: request.headers['x-signature'],
    );
    if (!verification.isValid) {
      return _verificationErrorResponse(verification.result);
    }
    return _json({'pong': true});
  });

  return router;
}
