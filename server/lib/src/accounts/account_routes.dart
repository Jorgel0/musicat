import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../identity/node_identity.dart';
import '../relay/username_directory_store.dart' show invalidUsernameFormatError;
import 'account.dart';
import 'account_request_auth.dart';
import 'account_store.dart';
import 'friend_request.dart';
import 'friend_request_store.dart';
import 'login_nonce_store.dart';
import 'login_rate_limiter.dart';

Response _json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Response _error(String message, {int status = 400}) =>
    _json({'error': message}, status: status);

Map<String, dynamic> _deviceJson(DeviceLink device) => device.toJson();

Map<String, dynamic> _friendRequestJson(FriendRequest request) => {
  'id': request.id,
  'fromAccountId': request.fromAccountId,
  'toAccountId': request.toAccountId,
  'status': request.status.name,
  'createdAt': request.createdAt.toIso8601String(),
};

Map<String, dynamic> _loginResponseJson(
  Account account, {
  required bool created,
}) => {
  'accountId': account.accountId,
  'username': account.username,
  'created': created,
  'devices': [for (final device in account.devices) _deviceJson(device)],
};

/// Authenticates [request]'s caller against [accountStore] via the
/// `X-Node-Id`/`X-Timestamp`/`X-Signature` shape [AccountRequestVerifier]
/// checks -- every account route below that isn't the public `login/*` or
/// `by-device` lookup goes through this, so "is this caller really a
/// device of some account" is answered identically everywhere. [body] must
/// be the *exact* raw request body the caller signed (or `''` for a
/// request with none) -- callers of this function must read it via
/// `request.readAsString()` themselves first (shelf request bodies are
/// single-subscription, so it can't be read twice) and reuse that same
/// string for any of their own JSON parsing.
///
/// Returns the calling [Account] on success, `null` otherwise -- every
/// caller below maps `null` onto a `401`.
Future<Account?> _authenticateCaller(
  Request request,
  AccountStore accountStore, {
  required String body,
}) async {
  final nodeId = request.headers['x-node-id'];
  final timestamp = request.headers['x-timestamp'];
  final signatureBase64 = request.headers['x-signature'];
  if (nodeId == null || timestamp == null || signatureBase64 == null) {
    return null;
  }

  final account = await accountStore.findByDeviceNodeId(nodeId);
  if (account == null) return null;

  final device = account.devices.firstWhere((d) => d.nodeId == nodeId);
  final result = await AccountRequestVerifier.verify(
    method: request.method,
    path: request.requestedUri.path,
    body: body,
    timestamp: timestamp,
    signatureBase64: signatureBase64,
    publicKeyBase64: device.publicKeyBase64,
  );
  return result == AccountRequestVerificationResult.valid ? account : null;
}

Response _respondOutcomeResponse(
  RespondOutcome outcome,
  FriendRequest? request,
) {
  switch (outcome) {
    case RespondOutcome.notFound:
      return _error('Unknown friend request', status: 404);
    case RespondOutcome.forbidden:
      return _error(
        'Only the recipient of a friend request can respond to it',
        status: 403,
      );
    case RespondOutcome.conflict:
      return _error(
        'Friend request was already ${request!.status.name}',
        status: 409,
      );
    case RespondOutcome.updated:
    case RespondOutcome.alreadyInThatState:
      return _json(_friendRequestJson(request!));
  }
}

/// Builds the `/accounts/*` routes -- see this module's own design brief
/// for the full contract; summarized here per route:
///
/// `POST /login/start` `{username}` -> `{nonceBase64}`. Deliberately does
/// the exact same work (generate a nonce, store it, return it) regardless
/// of whether [username] has a real account yet or not, and never touches
/// [accountStore] at all -- so its response's shape, status, and timing
/// never depend on that, which is this endpoint's whole answer to the
/// standard "does this account exist" enumeration concern. (`POST
/// /login/complete`'s *outcome* can still eventually reveal that once a
/// caller completes the full nonce+signature handshake -- an unavoidable
/// consequence of folding signup into login exactly as specified -- but
/// that costs a real Ed25519 proof-of-key-control per guess, not a cheap
/// repeatable query.)
///
/// `POST /login/complete` `{username, password, nodeId, publicKeyBase64,
/// signatureOverNonce}` -- verifies, in order: [loginRateLimiter] isn't
/// currently locking this username out (`429`); a pending nonce from
/// `login/start` exists for this exact username and hasn't expired or
/// already been consumed (`401`, single-use exactly like
/// `PairingCodeStore`); `nodeId` really is the SHA-256 fingerprint of
/// `publicKeyBase64` (`401`, self-certifying, same check as `RelayHub`);
/// `signatureOverNonce` really is that key's Ed25519 signature over the
/// redeemed nonce (`401`). Only then does it call
/// [AccountStore.loginOrSignup] -- creating the account (`201`) if
/// `username` didn't have one yet, or verifying `password` and linking the
/// device (`200`) if it did (`401` "Incorrect password" on a wrong one,
/// which also feeds [loginRateLimiter]). Never creates a second,
/// conflicting account on a race (see `AccountStore._mutationLock`).
///
/// `DELETE /<accountId>/devices/<nodeId>` -- authenticated as a signed
/// request from a device already linked to *that same* `accountId` (see
/// [_authenticateCaller]); `401` if not authenticated at all, `403` if
/// authenticated as a device of a *different* account. Unlinking an
/// already-unlinked (or never-linked) `nodeId` is a no-op `204`, same as
/// any idempotent `DELETE`.
///
/// `GET /by-device/<nodeId>` -- public, unauthenticated: `{accountId}` or
/// `404`.
///
/// `GET /<accountId>/devices` -- the full device list
/// (`{accountId, devices: [{nodeId, publicKeyBase64, linkedAt}, ...]}`).
/// Always allowed for `accountId` looking up its own devices; otherwise
/// gated on an `accepted` friend request existing between the caller's own
/// authenticated account and `accountId`, in either direction (`403` if
/// not, `404` if `accountId` isn't a known account at all, `401` if the
/// caller isn't authenticated).
///
/// `POST /<me>/friend-requests` `{toUsername}` -- authenticated as `<me>`;
/// resolves `toUsername` to an account (`404` if unknown), rejects sending
/// to yourself (`400`), and creates a `pending` request -- or, if one is
/// already `pending` in that exact direction, just returns the existing
/// one unchanged (`201` either way; see `FriendRequestStore.send`).
///
/// `GET /<me>/friend-requests?status=` -- authenticated as `<me>`; lists
/// every request currently addressed *to* `<me>`, optionally narrowed to a
/// single `status` (`pending`/`accepted`/`declined`; `400` for anything
/// else).
///
/// `POST /<me>/friend-requests/<requestId>/accept` and `.../decline` --
/// authenticated as `<me>`, which must be the request's *recipient*
/// (`403` otherwise -- the sender can never accept/decline their own
/// request); `404` if `requestId` doesn't exist; `409` if it's already
/// been accepted/declined the *other* way; a no-op success if it's already
/// in the exact state being requested.
Router buildAccountRouter(
  AccountStore accountStore,
  FriendRequestStore friendRequestStore, {
  LoginNonceStore? loginNonceStore,
  LoginRateLimiter? loginRateLimiter,
}) {
  final nonces = loginNonceStore ?? LoginNonceStore();
  final rateLimiter = loginRateLimiter ?? LoginRateLimiter();
  final router = Router();

  router.post('/login/start', (Request request) async {
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

    final nonce = nonces.generate(username);
    return _json({'nonceBase64': base64Encode(nonce)});
  });

  router.post('/login/complete', (Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final username = body['username'];
    final password = body['password'];
    final nodeId = body['nodeId'];
    final publicKeyBase64 = body['publicKeyBase64'];
    final signatureOverNonce = body['signatureOverNonce'];
    if (username is! String || username.isEmpty) {
      return _error('"username" is required');
    }
    if (password is! String || password.isEmpty) {
      return _error('"password" is required');
    }
    if (nodeId is! String || nodeId.isEmpty) {
      return _error('"nodeId" is required');
    }
    if (publicKeyBase64 is! String || publicKeyBase64.isEmpty) {
      return _error('"publicKeyBase64" is required');
    }
    if (signatureOverNonce is! String || signatureOverNonce.isEmpty) {
      return _error('"signatureOverNonce" is required');
    }

    if (rateLimiter.isLockedOut(username)) {
      return _error(
        'Too many failed attempts for this username. Try again later.',
        status: 429,
      );
    }

    final nonce = nonces.redeem(username);
    if (nonce == null) {
      return _error(
        'No pending login for this username, or it expired -- call '
        '/accounts/login/start again',
        status: 401,
      );
    }

    final List<int> publicKeyBytes;
    final List<int> signatureBytes;
    try {
      publicKeyBytes = base64Decode(publicKeyBase64);
      signatureBytes = base64Decode(signatureOverNonce);
    } on FormatException {
      return _error(
        '"publicKeyBase64" and "signatureOverNonce" must be valid base64',
      );
    }

    if (await nodeIdForPublicKey(publicKeyBytes) != nodeId) {
      return _error('"nodeId" does not match "publicKeyBase64"', status: 401);
    }

    final publicKey = SimplePublicKey(
      publicKeyBytes,
      type: KeyPairType.ed25519,
    );
    final signature = Signature(signatureBytes, publicKey: publicKey);
    final signatureIsValid = await Ed25519().verify(
      nonce,
      signature: signature,
    );
    if (!signatureIsValid) {
      return _error('Invalid signature over the login nonce', status: 401);
    }

    final result = await accountStore.loginOrSignup(
      username: username,
      password: password,
      nodeId: nodeId,
      publicKeyBase64: publicKeyBase64,
    );

    switch (result.outcome) {
      case LoginOutcome.invalidUsername:
        return _error(invalidUsernameFormatError, status: 400);
      case LoginOutcome.wrongPassword:
        rateLimiter.recordFailure(username);
        return _error('Incorrect password', status: 401);
      case LoginOutcome.created:
        rateLimiter.recordSuccess(username);
        return _json(
          _loginResponseJson(result.account!, created: true),
          status: 201,
        );
      case LoginOutcome.linked:
        rateLimiter.recordSuccess(username);
        return _json(_loginResponseJson(result.account!, created: false));
    }
  });

  router.get('/by-device/<nodeId>', (Request request, String nodeId) async {
    final account = await accountStore.findByDeviceNodeId(nodeId);
    if (account == null) return _error('Not found', status: 404);
    return _json({'accountId': account.accountId});
  });

  router.delete('/<accountId>/devices/<targetNodeId>', (
    Request request,
    String accountId,
    String targetNodeId,
  ) async {
    final body = await request.readAsString();
    final caller = await _authenticateCaller(request, accountStore, body: body);
    if (caller == null) {
      return _error('Authentication required', status: 401);
    }
    if (caller.accountId != accountId) {
      return _error('Not a device of this account', status: 403);
    }

    await accountStore.unlinkDevice(accountId, targetNodeId);
    return Response(204);
  });

  router.get('/<accountId>/devices', (Request request, String accountId) async {
    final body = await request.readAsString();
    final caller = await _authenticateCaller(request, accountStore, body: body);
    if (caller == null) {
      return _error('Authentication required', status: 401);
    }

    final target = await accountStore.findById(accountId);
    if (target == null) return _error('Not found', status: 404);

    if (caller.accountId != accountId) {
      final mutualFriends = await friendRequestStore.areMutualFriends(
        caller.accountId,
        accountId,
      );
      if (!mutualFriends) {
        return _error('Not a mutual friend of this account', status: 403);
      }
    }

    return _json({
      'accountId': target.accountId,
      'devices': [for (final device in target.devices) _deviceJson(device)],
    });
  });

  router.post('/<me>/friend-requests', (Request request, String me) async {
    final body = await request.readAsString();
    final caller = await _authenticateCaller(request, accountStore, body: body);
    if (caller == null) {
      return _error('Authentication required', status: 401);
    }
    if (caller.accountId != me) {
      return _error('Cannot act as another account', status: 403);
    }

    final Map<String, dynamic> parsedBody;
    try {
      parsedBody = body.isEmpty ? {} : jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final toUsername = parsedBody['toUsername'];
    if (toUsername is! String || toUsername.isEmpty) {
      return _error('"toUsername" is required');
    }

    final target = await accountStore.findByUsername(toUsername);
    if (target == null) return _error('Unknown username', status: 404);
    if (target.accountId == me) {
      return _error('Cannot send a friend request to yourself');
    }

    final friendRequest = await friendRequestStore.send(me, target.accountId);
    return _json(_friendRequestJson(friendRequest), status: 201);
  });

  router.get('/<me>/friend-requests', (Request request, String me) async {
    final body = await request.readAsString();
    final caller = await _authenticateCaller(request, accountStore, body: body);
    if (caller == null) {
      return _error('Authentication required', status: 401);
    }
    if (caller.accountId != me) {
      return _error('Cannot act as another account', status: 403);
    }

    final statusParam = request.requestedUri.queryParameters['status'];
    FriendRequestStatus? status;
    if (statusParam != null) {
      for (final candidate in FriendRequestStatus.values) {
        if (candidate.name == statusParam) status = candidate;
      }
      if (status == null) {
        return _error('Invalid "status" query parameter');
      }
    }

    final requests = await friendRequestStore.listAddressedTo(
      me,
      status: status,
    );
    return _json([
      for (final friendRequest in requests) _friendRequestJson(friendRequest),
    ]);
  });

  router.post('/<me>/friend-requests/<requestId>/accept', (
    Request request,
    String me,
    String requestId,
  ) async {
    final body = await request.readAsString();
    final caller = await _authenticateCaller(request, accountStore, body: body);
    if (caller == null) {
      return _error('Authentication required', status: 401);
    }
    if (caller.accountId != me) {
      return _error('Cannot act as another account', status: 403);
    }

    final (outcome, updated) = await friendRequestStore.accept(requestId, me);
    return _respondOutcomeResponse(outcome, updated);
  });

  router.post('/<me>/friend-requests/<requestId>/decline', (
    Request request,
    String me,
    String requestId,
  ) async {
    final body = await request.readAsString();
    final caller = await _authenticateCaller(request, accountStore, body: body);
    if (caller == null) {
      return _error('Authentication required', status: 401);
    }
    if (caller.accountId != me) {
      return _error('Cannot act as another account', status: 403);
    }

    final (outcome, updated) = await friendRequestStore.decline(requestId, me);
    return _respondOutcomeResponse(outcome, updated);
  });

  return router;
}
