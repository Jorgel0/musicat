import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../identity/node_identity.dart';
import '../relay/username_directory_store.dart' show invalidUsernameFormatError;
import 'account.dart';
import 'account_creation_limiter.dart';
import 'account_request_auth.dart';
import 'account_store.dart';
import 'device_notifier.dart';
import 'friend_request.dart';
import 'friend_request_store.dart';
import 'login_nonce_store.dart';
import 'login_rate_limiter.dart';

Response _json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

/// Every error this service sends: a human-readable [message], and -- on the
/// login path -- a stable machine-readable [code] beside it.
///
/// The code exists because `400` is genuinely two different refusals here (a
/// username that doesn't match the format rule, and a password shorter than
/// [minPasswordLength]), and the only other way for an app to tell them apart
/// is to match on the wording of [message] -- an implicit contract that
/// rewording a string silently breaks. [message] stays the thing shown to a
/// person; [code] is the thing branched on. Omitted (the key is simply
/// absent) wherever a status already says everything, so no existing response
/// shape changes.
Response _error(String message, {int status = 400, String? code}) =>
    _json({'error': message, 'code': ?code}, status: status);

/// The stable `code` values `POST /login/complete` sends beside its
/// `error` message -- the machine-readable half of that contract (see
/// [_error]). Constants rather than inline strings so a rename is a compile
/// error here and a grep everywhere else; the *values* are the wire contract
/// and must not change once an app matches on them.
///
/// Only the login path has these. Every other route's status code already
/// says everything its caller needs, and inventing codes nobody reads would
/// be a contract to keep for no benefit.
const String invalidUsernameCode = 'invalid_username';
const String passwordTooShortCode = 'password_too_short';
const String noSuchAccountCode = 'no_such_account';
const String ambiguousUsernameCode = 'ambiguous_username';
const String incorrectPasswordCode = 'incorrect_password';
const String loginRateLimitedCode = 'rate_limited';
const String tooManyNewAccountsCode = 'too_many_new_accounts';

/// The two `401`s that are *not* a wrong password: the single-use nonce was
/// missing/expired, and the proof of key control didn't check out. A caller
/// cannot fix either by asking the user for a better password, which is
/// exactly why they are told apart from [incorrectPasswordCode].
const String loginExpiredCode = 'login_expired';
const String loginInvalidProofCode = 'invalid_login_proof';

/// The longest `deviceName` `POST /login/complete` will record (see
/// [DeviceLink.deviceName]). Generous for a platform label and small enough
/// that a node cannot use its own device row to bloat the responses this
/// service sends to that account's friends.
const int maxDeviceNameLength = 64;

/// [forSelf] is what gates [DeviceLink.lastLoginAt]: an account may see when
/// each of its own devices last logged in, and a mutual friend reading the
/// same route may not — they need the keys, not a last-seen signal per
/// device. Not defaulted, so every call site has to state which it is.
Map<String, dynamic> _deviceJson(DeviceLink device, {required bool forSelf}) =>
    device.toJson(includeLastLogin: forSelf);

/// The key [AccountCreationLimiter] counts against: the source address this
/// request really arrived from, or a single shared bucket when there is none
/// (a synthetic request with no socket behind it -- the same
/// `shelf.io.connection_info` key `requireLocal` reads, and the same
/// treatment of its absence: no special trust for a caller that can't be
/// placed).
///
/// `X-Forwarded-For` is honoured **only when the connection itself came
/// from loopback**, which is the one case where the header cannot have been
/// set by the caller: nothing but a process on this machine can open that
/// socket, and on the deployed relay that process is the TLS terminator in
/// front of it (ADR 0055). Read from a remote connection the same header
/// would be an attacker-supplied string handing them a fresh budget per
/// request -- strictly worse than no limiter at all, which is why the
/// limiter's own doc comment refuses it outright and why the loopback test
/// here is the whole basis for making an exception.
///
/// The *last* value is taken, not the first: a proxy appends the peer it
/// actually saw, so anything to its left was supplied by that peer and is
/// exactly as untrustworthy as the remote case above. (The deployed Caddy
/// config replaces the header rather than appending, so there is normally
/// only one.)
String _clientKeyOf(Request request) {
  final connectionInfo = request.context['shelf.io.connection_info'];
  if (connectionInfo is! HttpConnectionInfo) return 'unknown';

  final peer = connectionInfo.remoteAddress;
  if (peer.isLoopback) {
    final forwarded = request.headers['x-forwarded-for'];
    if (forwarded != null) {
      final last = forwarded.split(',').last.trim();
      if (last.isNotEmpty && InternetAddress.tryParse(last) != null) {
        return last;
      }
    }
  }
  return peer.address;
}

/// Every account's current username, by accountId -- one file read, reused
/// for every request in a response, instead of one [AccountStore.findById]
/// (and therefore one full read of `accounts.json`) per side of per request.
Future<Map<String, String>> _usernamesById(AccountStore accountStore) async => {
  for (final account in await accountStore.loadAll())
    account.accountId: account.username,
};

/// [request] as the wire shape [AccountFriendRequest] documents, with both
/// sides' usernames resolved from [usernames] (see [_usernamesById]) -- an
/// accountId is not something an app can show a human, which is the entire
/// reason this projection exists.
Map<String, dynamic> _friendRequestJson(
  FriendRequest request,
  Map<String, String> usernames,
) => AccountFriendRequest(
  id: request.id,
  fromAccountId: request.fromAccountId,
  fromUsername: usernames[request.fromAccountId],
  toAccountId: request.toAccountId,
  toUsername: usernames[request.toAccountId],
  status: request.status.name,
  createdAt: request.createdAt,
).toJson();

/// Nudges every currently-connected device of [accountId] with
/// [AccountEvent.friendRequests] -- the push half of "push for convenience,
/// poll for correctness" (see [DeviceNotifier] and [RelayNotify]).
///
/// **Fire-and-forget, and it must stay that way.** Every caller wraps this
/// in `unawaited`, so the HTTP response is already on its way before the
/// device list is even read: a push is best-effort by definition, and a slow
/// or failing one must never delay, let alone fail, the accept/decline/send
/// it is announcing. Every failure mode -- no notifier configured, an
/// account that vanished, a device with no tunnel, a tunnel that just died
/// -- is silent and equivalent, because the receiving node's own poll makes
/// all of them converge anyway.
///
/// Notifies *every* device of the account, including the one that made the
/// call. Excluding the caller would be a special case worth exactly one
/// redundant re-fetch, and getting it wrong (excluding a device that is
/// merely on the same account) would silently break the multi-device case
/// this service exists for.
Future<void> _notifyAccountDevices(
  AccountStore accountStore,
  DeviceNotifier? notifier,
  String accountId,
) async {
  if (notifier == null) return;
  try {
    final account = await accountStore.findById(accountId);
    if (account == null) return;
    for (final device in account.devices) {
      notifier.notifyDevice(device.nodeId, AccountEvent.friendRequests);
    }
  } catch (_) {
    // Deliberately silent: see this function's own doc comment. There is no
    // caller that could do anything useful with a failed push.
  }
}

Map<String, dynamic> _loginResponseJson(
  Account account, {
  required bool created,
}) => {
  'accountId': account.accountId,
  'username': account.username,
  'created': created,
  'devices': [
    for (final device in account.devices) _deviceJson(device, forSelf: true),
  ],
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

Future<Response> _respondOutcomeResponse(
  RespondOutcome outcome,
  FriendRequest? request,
  AccountStore accountStore,
) async {
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
      return _json(
        _friendRequestJson(request!, await _usernamesById(accountStore)),
      );
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
/// signatureOverNonce, relayUrl?, allowCreate?}` -- verifies, in order:
/// [loginRateLimiter] isn't
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
/// **Usernames are case-insensitive** ([normalizeUsername]) everywhere here:
/// stored, matched, echoed back canonical, and used as the key for both the
/// nonce and the rate limiter -- that last one matters, since a limiter keyed
/// by the raw string would give an attacker a fresh five guesses per
/// capitalization. `409` for the one case that cannot be resolved: two
/// pre-existing accounts differing only by case, which this refuses to choose
/// between rather than silently shadowing one (see
/// [AccountStore.findAllByUsername]).
///
/// **`allowCreate` (optional, default `true`) makes account creation opt-in
/// on the wire.** With `false`, a username that has no account is answered
/// `404 {"error": ...}` and nothing is written or hashed; the app calls with
/// `false` first and re-sends with `true` once the user has confirmed they
/// really mean to create one. That default keeps every existing caller
/// working unchanged. It is a mild account-existence oracle -- a `404`
/// instead of a `201` says the name is free -- and that is acceptable here
/// for exactly the reason ADR 0048 already accepted for `login/complete`'s
/// outcome generally: reaching it costs a `login/start` round trip plus a
/// real Ed25519 signature over that specific nonce per guess, which is a far
/// higher bar than a cheap repeatable query, and `login/start` itself still
/// leaks nothing.
///
/// **A new account's password must be at least [minPasswordLength]
/// characters** (`400`, with the minimum named in the message). Creation
/// only: an existing account's password is never length-checked, because
/// refusing one written before this rule would lock its owner out of their
/// own account.
///
/// **Creating an account is rate-limited per source address**
/// ([accountCreationLimiter], `429`), which [loginRateLimiter] never covered:
/// it counts failures, and a signup is a success. See
/// [AccountCreationLimiter] for what that does and does not stop.
///
/// **A device ends up linked to exactly one account.** Logging in as a
/// different account unlinks this device from whichever one it was on, which
/// is what makes a second account on the same device usable at all -- see
/// [AccountStore.findByDeviceNodeId].
///
/// The optional `deviceName` is the logging-in device's own platform label
/// (`Android`, `Linux`, ...), refreshed on every login on exactly the same
/// terms as `relayUrl`, capped at [maxDeviceNameLength] characters, and
/// returned by `GET /<accountId>/devices` so a person can tell their own
/// devices apart before unlinking one. See [DeviceLink.deviceName] for why it
/// is a platform and not a hostname.
///
/// The optional `relayUrl` is the logging-in device's own relay endpoint,
/// and **every login refreshes it**, including a re-login from an
/// already-linked device (sending none clears it). It is the one piece of
/// reachability this service records, and it exists so two people who become
/// friends purely here can actually reach each other -- see
/// [DeviceLink.relayUrl] for the full rationale, including what it discloses
/// to whom.
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
/// (`{accountId, devices: [{nodeId, publicKeyBase64, linkedAt, relayUrl},
/// ...]}`).
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
/// `GET /<me>/friend-requests?status=&direction=` -- authenticated as
/// `<me>`; lists the requests `<me>` is one side of, optionally narrowed to a
/// single `status` (`pending`/`accepted`/`declined`/`revoked`/`cancelled`;
/// `400` for anything else). Every friend-request response here (this one,
/// `send`, `accept`, `decline` and `cancel`) carries both sides'
/// **usernames** alongside their accountIds -- see [AccountFriendRequest].
///
/// **`direction` (optional, `incoming` when absent)** picks which side:
/// `incoming` (addressed to `<me>` -- what this route has always returned,
/// so no existing caller changes), `outgoing` (sent by `<me>`), or `both` in
/// one answer. A parameter rather than a second route on purpose: the
/// authentication, the `<me>` check, the status filter and the username
/// projection are identical either way, and only the field compared to
/// `<me>` differs -- two routes would duplicate all of that and be free to
/// drift, and `both` in particular exists so an app showing both lists (which
/// is every app) spends one signed round trip instead of two.
///
/// `GET /<me>/friends` -- authenticated as `<me>`; every account `<me>`
/// has an *accepted* friend request with, in either direction, as
/// `[{accountId, username, devices: [...]}, ...]` (each device including
/// its [DeviceLink.relayUrl], which is what makes a friend learned here
/// reachable at all) (a bare JSON array, like
/// its `GET /<me>/friend-requests` sibling). This is the endpoint a node's
/// own `FriendSyncService` polls to learn who it is friends with; see
/// [AccountFriend] for why each friend's device list is inlined rather than
/// left to a follow-up `GET /<accountId>/devices` per friend.
///
/// `DELETE /<me>/friends/<accountId>` -- authenticated as `<me>`; ends an
/// accepted friendship **from either side**, whichever of the two originally
/// sent the request (see [FriendRequestStore.revokeFriendship]). Always
/// `204` with no body, and deliberately idempotent: revoking a friendship
/// that doesn't exist, or that was already revoked, or naming an account
/// that was never real, all do nothing and answer the same way -- so a
/// node's retry of a revocation it isn't sure landed is free and safe, and
/// the route is no account-enumeration oracle either. `401` if not
/// authenticated at all, `403` if authenticated as a *different* account
/// (nobody may revoke somebody else's friendships). Afterwards
/// [FriendRequestStore.areMutualFriends] is false for the pair, which closes
/// `GET /<accountId>/devices` and drops each side from the other's
/// `GET /<me>/friends` -- for **both** accounts, since that gate was
/// symmetric all along. A later re-friend is an ordinary new request.
///
/// `POST /<me>/friend-requests/<requestId>/accept` and `.../decline` --
/// authenticated as `<me>`, which must be the request's *recipient*
/// (`403` otherwise -- the sender can never accept/decline their own
/// request); `404` if `requestId` doesn't exist; `409` if it's already
/// been accepted/declined the *other* way; a no-op success if it's already
/// in the exact state being requested.
///
/// `POST /<me>/friend-requests/<requestId>/cancel` -- the mirror image:
/// authenticated as `<me>`, which must be the request's **sender** (`403`
/// otherwise, the recipient included -- their way out is `decline`, and the
/// two are recorded as different statuses because they are different
/// people's decisions). `404` for an unknown id, `409` once it has been
/// answered (a request the other side accepted is a friendship now, and
/// ending one of those is `DELETE /<me>/friends/<accountId>`), and a no-op
/// `200` for one already cancelled, so a retry is free. The row is flipped
/// to `cancelled`, never deleted -- see [FriendRequestStatus.cancelled].
///
/// [deviceNotifier] is optional and defaults to `null` -- with none, this
/// service works exactly as it did before push existed, and every existing
/// caller (and every node whose relay hosts no account service) keeps
/// working unchanged. When one *is* given, `POST /<me>/friend-requests`, its
/// `accept`/`decline`/`cancel` siblings and `DELETE /<me>/friends/<accountId>`
/// nudge the affected accounts' devices afterwards; see
/// [_notifyAccountDevices] for who is notified and why that push can never
/// carry data.
Router buildAccountRouter(
  AccountStore accountStore,
  FriendRequestStore friendRequestStore, {
  LoginNonceStore? loginNonceStore,
  LoginRateLimiter? loginRateLimiter,
  AccountCreationLimiter? accountCreationLimiter,
  DeviceNotifier? deviceNotifier,
}) {
  final nonces = loginNonceStore ?? LoginNonceStore();
  final rateLimiter = loginRateLimiter ?? LoginRateLimiter();
  final creationLimiter = accountCreationLimiter ?? AccountCreationLimiter();
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

    // Keyed by the canonical spelling, so `login/complete` -- which
    // normalizes the same way -- finds the nonce whichever case the caller
    // used for either call.
    final nonce = nonces.generate(normalizeUsername(username));
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
    final relayUrl = body['relayUrl'];
    final deviceName = body['deviceName'];
    final allowCreate = body['allowCreate'];
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
    // Optional, and the *only* reachability this service ever records (see
    // [DeviceLink.relayUrl]). An empty string is normalized to null rather
    // than rejected: it means the same thing a node with no relay means, and
    // failing a login over it would be an absurd way to find out.
    if (relayUrl != null && relayUrl is! String) {
      return _error('"relayUrl" must be a string if present');
    }
    // Optional, same shape and same "empty means none" rule as relayUrl (see
    // [DeviceLink.deviceName]). Length-capped because this string is
    // node-supplied, stored in `accounts.json`, and handed to every mutual
    // friend: a node that sent a megabyte of it would be writing into other
    // people's responses, and no honest platform label is anywhere near this
    // long.
    if (deviceName != null && deviceName is! String) {
      return _error('"deviceName" must be a string if present');
    }
    if (deviceName is String && deviceName.length > maxDeviceNameLength) {
      return _error(
        '"deviceName" must be at most $maxDeviceNameLength characters',
      );
    }
    // Optional, and `true` when absent -- the behaviour this endpoint has
    // always had, so every existing caller is unaffected. See this router's
    // doc comment for what `false` buys and what it discloses.
    if (allowCreate != null && allowCreate is! bool) {
      return _error('"allowCreate" must be a boolean if present');
    }

    // Every key below is the canonical spelling: usernames are
    // case-insensitive, and a rate limiter keyed by the raw string would
    // hand an attacker a fresh budget of guesses per capitalization of the
    // same account.
    final canonicalUsername = normalizeUsername(username);

    if (rateLimiter.isLockedOut(canonicalUsername)) {
      return _error(
        'Too many failed attempts for this username. Try again later.',
        status: 429,
        code: loginRateLimitedCode,
      );
    }

    final nonce = nonces.redeem(canonicalUsername);
    if (nonce == null) {
      return _error(
        'No pending login for this username, or it expired -- call '
        '/accounts/login/start again',
        status: 401,
        code: loginExpiredCode,
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
      return _error(
        '"nodeId" does not match "publicKeyBase64"',
        status: 401,
        code: loginInvalidProofCode,
      );
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
      return _error(
        'Invalid signature over the login nonce',
        status: 401,
        code: loginInvalidProofCode,
      );
    }

    // Whether this attempt is about to *create* an account, which
    // [AccountCreationLimiter] throttles and an ordinary login must not be
    // charged for. Read outside [AccountStore]'s lock and therefore
    // advisory: a race here can only mean one creation slipping past the cap
    // or one login briefly looking like a creation, and the definitive
    // answer -- `result.outcome` below -- is what is actually recorded.
    final wouldCreate =
        await accountStore.findByUsername(canonicalUsername) == null;
    final clientKey = _clientKeyOf(request);
    if (wouldCreate && !creationLimiter.allows(clientKey)) {
      return _error(
        'Too many new accounts from this address. Try again later.',
        status: 429,
        code: tooManyNewAccountsCode,
      );
    }

    final result = await accountStore.loginOrSignup(
      username: canonicalUsername,
      password: password,
      nodeId: nodeId,
      publicKeyBase64: publicKeyBase64,
      relayUrl: (relayUrl is String && relayUrl.isNotEmpty) ? relayUrl : null,
      deviceName: (deviceName is String && deviceName.isNotEmpty)
          ? deviceName
          : null,
      allowCreate: allowCreate as bool? ?? true,
    );

    switch (result.outcome) {
      case LoginOutcome.invalidUsername:
        return _error(
          invalidUsernameFormatError,
          status: 400,
          code: invalidUsernameCode,
        );
      case LoginOutcome.passwordTooShort:
        return _error(
          'Password must be at least $minPasswordLength characters',
          status: 400,
          code: passwordTooShortCode,
        );
      case LoginOutcome.noSuchAccount:
        // Deliberately not fed to [rateLimiter]: this is not a guess at
        // anybody's password, and counting it would let a stranger lock a
        // *free* username out of being signed up for.
        return _error(
          'No account with that username',
          status: 404,
          code: noSuchAccountCode,
        );
      case LoginOutcome.ambiguousUsername:
        return _error(
          'This username is held by two accounts that differ only in '
          'capitalization. An operator has to resolve that before either '
          'can be used.',
          status: 409,
          code: ambiguousUsernameCode,
        );
      case LoginOutcome.wrongPassword:
        rateLimiter.recordFailure(canonicalUsername);
        return _error(
          'Incorrect password',
          status: 401,
          code: incorrectPasswordCode,
        );
      case LoginOutcome.created:
        rateLimiter.recordSuccess(canonicalUsername);
        creationLimiter.record(clientKey);
        return _json(
          _loginResponseJson(result.account!, created: true),
          status: 201,
        );
      case LoginOutcome.linked:
        rateLimiter.recordSuccess(canonicalUsername);
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

    final forSelf = caller.accountId == accountId;
    return _json({
      'accountId': target.accountId,
      'devices': [
        for (final device in target.devices)
          _deviceJson(device, forSelf: forSelf),
      ],
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
    // The recipient is the only account whose view actually changed (a new
    // pending request); the sender is right here holding the response.
    unawaited(
      _notifyAccountDevices(accountStore, deviceNotifier, target.accountId),
    );
    return _json(
      _friendRequestJson(friendRequest, await _usernamesById(accountStore)),
      status: 201,
    );
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

    // Absent means `incoming`, which is what this route has always returned
    // -- so every existing caller, including a node too old to know this
    // parameter exists, is unaffected. See this router's doc comment for why
    // outgoing requests are a direction here rather than a route of their
    // own.
    final directionParam = request.requestedUri.queryParameters['direction'];
    FriendRequestDirection? direction;
    if (directionParam != null) {
      for (final candidate in FriendRequestDirection.values) {
        if (candidate.name == directionParam) direction = candidate;
      }
      if (direction == null) {
        return _error('Invalid "direction" query parameter');
      }
    }

    final requests = await friendRequestStore.list(
      me,
      direction: direction ?? FriendRequestDirection.incoming,
      status: status,
    );
    final usernames = await _usernamesById(accountStore);
    return _json([
      for (final friendRequest in requests)
        _friendRequestJson(friendRequest, usernames),
    ]);
  });

  // Registered among the other two-segment `/<id>/<literal>` routes, and
  // safe anywhere among them: shelf_router matches in registration order
  // with no most-specific-first rule (the trap `bin/relay.dart` and
  // `musicat_server_runtime.dart` both call out), so overlap is what
  // matters -- and `friends` overlaps nothing. `/<accountId>/devices` and
  // `/<me>/friend-requests` each pin a *different literal* second segment,
  // and `friends` is not a prefix-match of `friend-requests` (shelf_router
  // matches whole segments, not prefixes). Verified against the real
  // mounted server, not just this router, in `account_routes_test.dart` --
  // mounting is exactly where this class of mistake has hidden before.
  router.get('/<me>/friends', (Request request, String me) async {
    final body = await request.readAsString();
    final caller = await _authenticateCaller(request, accountStore, body: body);
    if (caller == null) {
      return _error('Authentication required', status: 401);
    }
    if (caller.accountId != me) {
      return _error('Cannot act as another account', status: 403);
    }

    final friendIds = await friendRequestStore.listAcceptedFriendAccountIds(me);
    final friends = <AccountFriend>[];
    for (final friendId in friendIds) {
      final friend = await accountStore.findById(friendId);
      // An accepted request naming an account that no longer exists is not
      // currently reachable (accounts are never deleted), but skipping it
      // rather than failing the whole response keeps one bad row from
      // costing a node its entire friend list -- and a node that receives a
      // short list simply learns less, since the sync consuming this is
      // additive-only and never removes anything.
      if (friend == null) continue;
      friends.add(
        AccountFriend(
          accountId: friend.accountId,
          username: friend.username,
          devices: friend.devices,
        ),
      );
    }

    return _json([for (final friend in friends) friend.toJson()]);
  });

  // Three segments with `friends` pinned in the middle, so it overlaps
  // neither `DELETE /<accountId>/devices/<targetNodeId>` (which pins
  // `devices`) nor anything else registered here -- the same
  // registration-order care the `GET /<me>/friends` comment above spells
  // out. Also verified against the real mounted server in
  // `account_routes_test.dart` rather than only against this router.
  router.delete('/<me>/friends/<friendAccountId>', (
    Request request,
    String me,
    String friendAccountId,
  ) async {
    final body = await request.readAsString();
    final caller = await _authenticateCaller(request, accountStore, body: body);
    if (caller == null) {
      return _error('Authentication required', status: 401);
    }
    if (caller.accountId != me) {
      return _error('Cannot act as another account', status: 403);
    }

    final revoked = await friendRequestStore.revokeFriendship(
      me,
      friendAccountId,
    );
    if (revoked > 0) {
      // Both sides, and the far side is the one that matters: nothing else
      // would ever tell them their friend list just shrank, and until they
      // re-fetch they still hold that account's cached device keys. `<me>`'s
      // *other* devices are told for the same reason accept tells them --
      // their own friend list changed too.
      //
      // Deliberately only on a real change. A no-op revocation (they were
      // never friends, or a retry of one that already landed) pushes
      // nothing, so this route can't be used as a free way to make some
      // other account's devices poll on demand.
      unawaited(_notifyAccountDevices(accountStore, deviceNotifier, me));
      unawaited(
        _notifyAccountDevices(accountStore, deviceNotifier, friendAccountId),
      );
    }
    return Response(204);
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
    if (outcome == RespondOutcome.updated) {
      // Both sides' views changed, and for different reasons: the sender has
      // gained a friend (the important one -- nothing else would ever tell
      // them), and `<me>`'s *other* devices have lost a pending request and
      // gained the same friend. The accepting device is notified too; see
      // [_notifyAccountDevices].
      unawaited(
        _notifyAccountDevices(
          accountStore,
          deviceNotifier,
          updated!.fromAccountId,
        ),
      );
      unawaited(_notifyAccountDevices(accountStore, deviceNotifier, me));
    }
    return _respondOutcomeResponse(outcome, updated, accountStore);
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
    if (outcome == RespondOutcome.updated) {
      // Only `<me>`'s own devices: their pending list just shrank. The
      // *sender* is deliberately still not told, even now that they can list
      // their own outgoing requests: a push here would be a "you were
      // declined, this second" side channel, and the thing it would save them
      // is one poll interval of a row they can no longer act on anyway (a
      // declined request simply stops appearing in their pending outgoing
      // list). Cancel below is the mirror case and *does* push, because there
      // the person who needs telling is the one still being shown a prompt.
      unawaited(_notifyAccountDevices(accountStore, deviceNotifier, me));
    }
    return _respondOutcomeResponse(outcome, updated, accountStore);
  });

  // Four segments with `friend-requests` and `cancel` both pinned, exactly
  // like its `accept`/`decline` siblings above -- it overlaps none of them,
  // and registration order among the three is irrelevant because they differ
  // in their final literal segment. Registered here rather than beside them
  // for readability only.
  router.post('/<me>/friend-requests/<requestId>/cancel', (
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

    final (outcome, updated) = await friendRequestStore.cancel(requestId, me);
    if (outcome == RespondOutcome.updated) {
      // The recipient first, and they are the point: until they re-fetch they
      // are still being shown, and can still accept, a request that no longer
      // exists -- the one case where a missed push has a user acting on
      // something withdrawn. `<me>`'s other devices are told for the same
      // reason accept tells them: their own outgoing list changed too.
      //
      // Only on a real change, like `DELETE /<me>/friends/<accountId>`: a
      // no-op cancel (already cancelled, or somebody else's request) pushes
      // nothing, so this cannot be used as a free way to make another
      // account's devices poll on demand.
      unawaited(
        _notifyAccountDevices(
          accountStore,
          deviceNotifier,
          updated!.toAccountId,
        ),
      );
      unawaited(_notifyAccountDevices(accountStore, deviceNotifier, me));
    }
    return _respondOutcomeResponse(outcome, updated, accountStore);
  });

  return router;
}
