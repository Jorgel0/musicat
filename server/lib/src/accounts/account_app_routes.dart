import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../federation/account_update_poller.dart';
import '../http/require_local.dart';
import 'account.dart';
import 'account_service_client.dart';
import 'account_session_store.dart';
import 'pending_friend_request_cache.dart';

Response _json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Response _error(String message, {int status = 400}) =>
    _json({'error': message}, status: status);

/// The account service's own failure, translated into a status this node's
/// app can act on. Kept as one exhaustive switch rather than spread through
/// the route so adding an [AccountLoginOutcome] is a compile error here
/// instead of a silent `500`.
Response _loginFailureResponse(AccountLoginResult result) {
  final (status, fallback) = switch (result.outcome) {
    AccountLoginOutcome.wrongPassword => (401, 'Incorrect password'),
    AccountLoginOutcome.rateLimited => (
      429,
      'Too many failed attempts for this username. Try again later.',
    ),
    AccountLoginOutcome.invalidUsername => (400, 'Invalid username'),
    AccountLoginOutcome.serviceUnreachable => (
      503,
      'Could not reach the account service',
    ),
    AccountLoginOutcome.failed => (
      502,
      'The account service could not complete this login',
    ),
    // Unreachable: this function is only ever called for a failure.
    AccountLoginOutcome.created ||
    AccountLoginOutcome.linked => throw StateError('not a failure'),
  };
  // The service's own message when it sent one -- it is more specific than
  // anything guessable here (a `401` also covers an expired login nonce, not
  // just a wrong password), and it never contains anything the caller
  // submitted, so forwarding it can't echo a password back.
  return _error(result.error ?? fallback, status: status);
}

/// A friend-request action's failure, translated into a status this node's
/// app can act on -- the same exhaustive-switch shape (and the same reason
/// for it) as [_loginFailureResponse] above.
Response _friendRequestFailureResponse(FriendRequestActionResult result) {
  final (status, fallback) = switch (result.outcome) {
    FriendRequestActionOutcome.notFound => (404, 'Not found'),
    FriendRequestActionOutcome.forbidden => (
      403,
      'The account service refused this action',
    ),
    FriendRequestActionOutcome.conflict => (
      409,
      'That friend request has already been answered',
    ),
    FriendRequestActionOutcome.invalid => (400, 'Invalid friend request'),
    FriendRequestActionOutcome.serviceUnreachable => (
      503,
      'Could not reach the account service',
    ),
    FriendRequestActionOutcome.failed => (
      502,
      'The account service could not complete this action',
    ),
    // Unreachable: only ever called for a failure.
    FriendRequestActionOutcome.ok => throw StateError('not a failure'),
  };
  // The service's own message where it sent one: it is more specific than
  // anything guessable here ("Unknown username" versus "Unknown friend
  // request" are both 404s), and it never contains a credential.
  return _error(result.error ?? fallback, status: status);
}

/// Builds this node's own app-facing `/api/v1/account/*` routes: which
/// portable account (ADR 0048) this device is logged in as.
///
/// **Node-side, not account-service-side.** This module holds both halves of
/// the account feature, and the split is by direction: `account_routes.dart`
/// and the stores beside it are the *service* (deployed on the relay,
/// holding password hashes); this file, `account_service_client.dart` and
/// `account_session_store.dart` are what a *node* runs. It lives here rather
/// than in `federation_routes.dart` because its collaborators are entirely
/// account-shaped — the session store, the service client, the friend sync —
/// and none of the pairing/NAT/relay state that file is built around, so
/// putting it there would give it reach it has no business having.
///
/// Every route below is app-facing: this device's own app talking to its own
/// local server, never a friend's server and never anything arriving through
/// the relay tunnel. They are all wrapped in [requireLocal] with
/// [appApiKey] (ADR 0044) — the login route above all, since it is the one
/// place in this whole codebase that ever accepts a password.
///
/// `POST /login` `{username, password}` — runs the account service's
/// two-step signed login (see [AccountServiceClient.login]), persists the
/// resulting session, and then runs one immediate friend sync before
/// answering, so a `200` means the local friend list already reflects this
/// account's accepted friendships. Returns
/// `{accountId, username, created}` — `created` distinguishing a brand-new
/// account from this device being linked to an existing one. A failed sync
/// never fails the login (the session is already persisted and the next sync
/// will retry); a failed *login* never touches the session at all, so a
/// wrong password can't log you out of the account you were already in.
/// Maps the client's outcomes to `401` (wrong password), `429`
/// (rate-limited), `400` (invalid username), `503` (account service
/// unreachable, or none configured on this node) and `502` (it answered, but
/// unusably) — see [_loginFailureResponse].
///
/// The password is read from the JSON body and passed straight to
/// [AccountServiceClient.login]. It is never a query parameter (paths and
/// query strings are what `logRequests()` and every proxy in between write
/// down), never persisted, and never echoed back in any response.
///
/// `GET /` — `{"account": {accountId, username, loggedInAt} | null}`, always
/// `200`. A `null` field rather than a `404` is how this API already says
/// "nothing here" for a single optional thing (`GET
/// /api/v1/soulseek/downloads-directory` answers `{"directory": ... | null}`
/// the same way), and it keeps "not logged in" distinguishable from "that
/// route doesn't exist" without the app having to special-case a status.
/// Answered from local disk: reading who you are must not need the account
/// service (Rule 1).
///
/// `DELETE /` — clears the session; `204` whether or not there was one, like
/// every other `DELETE` here. **It deliberately leaves [FriendStore]
/// completely alone.** Logging out is not unfriending: the friendships are
/// this device's own local trust, they keep working offline, and silently
/// dropping every friend because someone logged out to switch accounts would
/// be an unrecoverable surprise (there is no undo — re-adding each friend
/// means pairing again). The friends learned from an account simply stay
/// until the user removes them on purpose. It *does* clear
/// [pendingRequests], which is in-memory and belongs to whoever was logged
/// in: the next user of this node must not be shown the previous one's
/// prompts.
///
/// ## Friend requests (round B)
///
/// Four routes, all `requireLocal` like everything else here, all proxying
/// this node's logged-in account to the account service and signing as this
/// node's own device. Every one of them answers **`409`** when this node has
/// no session at all, and `503` when it has no account service configured --
/// `409` rather than `401` deliberately: the *caller* is perfectly
/// authorized (it already passed [requireLocal]), it is this node that has
/// nobody to act as, which is a conflict with the resource's state, not a
/// missing credential. `GET /api/v1/account` is how an app asks whether that
/// is the case, and it never errors.
///
/// `GET /friend-requests` — the still-pending requests addressed *to* this
/// account, as `{requests: [...], fetchedAt, live}`. Fetches live from the
/// account service and refreshes [pendingRequests] on the way past; if that
/// fetch fails, answers `200` with the last snapshot this node holds and
/// `live: false` instead of an error, so a dead relay degrades to a slightly
/// stale list rather than a broken screen. `fetchedAt` is `null` exactly when
/// this node has *never* successfully fetched, which is the one case an app
/// must not render as "no friend requests". Each entry is verbatim what the
/// account service returned (see [AccountFriendRequest]) — notably including
/// `fromUsername`, since an accountId is not something to show a human.
///
/// `POST /friend-requests` `{toUsername}` — sends one; `201` with the
/// created request. Idempotent upstream: sending again while one is still
/// pending returns the existing request rather than creating a second.
/// Maps the service's own refusals through
/// [_friendRequestFailureResponse] (`404` unknown username, `400`
/// befriending yourself, ...).
///
/// `POST /friend-requests/<id>/accept` and `.../decline` — answer one; `200`
/// with the updated request. **Accept runs one immediate, forced refresh
/// before responding**, exactly as `POST /login` does, so by the time the app
/// sees its `200` the new friend is already in
/// `GET /api/v1/federation/friends` and there is nothing to poll for.
/// Decline refreshes too, so the answered request is gone from
/// [pendingRequests] immediately.
///
/// That refresh goes through the ordinary sync path and therefore through
/// [FriendStore.addFromAccountService], which refuses a tombstoned account
/// inside its own lock. **Accepting a friend request cannot resurrect
/// somebody this device deliberately removed** — the accept succeeds on the
/// account service (it is a fact about the account, not about this device),
/// and this device still refuses to trust them locally until the user
/// re-adds them on purpose. Rule 2 has no exception here, and this route
/// deliberately does not reach for [FriendStore.add] to make one.
///
/// [pendingRequests] and [accountUpdates] are both optional so this router
/// can still be built (and still answer `GET`/`DELETE /`) on a node with no
/// account service at all.
Router buildAccountAppRouter({
  required AccountSessionStore sessionStore,
  AccountServiceClient? accountService,
  AccountUpdatePoller? accountUpdates,
  PendingFriendRequestCache? pendingRequests,
  String? myRelayUrl,
  String? appApiKey,
}) {
  final router = Router();

  router.post(
    '/login',
    requireLocal((Request request) async {
      // `null` exactly when this node was started without an
      // `accountServiceUrl` -- the default. Accounts are opt-in, so this is
      // an ordinary configuration, not an error state: answer the same
      // `503` the relay-less `POST /username` route answers, rather than
      // crashing on a null.
      if (accountService == null) {
        return _error(
          'No account service is configured for this node',
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
      final password = body['password'];
      if (username is! String || username.isEmpty) {
        return _error('"username" is required');
      }
      if (password is! String || password.isEmpty) {
        return _error('"password" is required');
      }

      final result = await accountService.login(
        username: username,
        password: password,
        // This node's own relay, published to the account service so friends
        // made purely through friend requests can reach it at all (see
        // [DeviceLink.relayUrl]). `null` when this node has no relay
        // configured, or couldn't connect to the one it has -- in which case
        // it publishes nothing and stays reachable only by direct address.
        relayUrl: myRelayUrl,
      );
      if (!result.isSuccess) return _loginFailureResponse(result);

      final session = await sessionStore.save(
        accountId: result.accountId!,
        username: result.username!,
      );

      // Awaited, not fired and forgotten: by the time the app sees this
      // `200`, `GET /api/v1/federation/friends` already reflects the
      // account's accepted friendships and this node's pending friend
      // requests are cached, so the UI has nothing to poll for. Bounded by
      // `AccountServiceClient.timeout` and forced past `minSyncInterval`,
      // because a person pressing "log in" is exactly the caller that must
      // never be silently throttled. Its outcome is deliberately not
      // reported: a refresh that failed leaves a perfectly valid session
      // behind, and the next one retries.
      await accountUpdates?.refreshNow(force: true);

      return _json({
        'accountId': session.accountId,
        'username': session.username,
        'created': result.created,
      });
    }, appApiKey: appApiKey),
  );

  router.get(
    '/',
    requireLocal((Request request) async {
      final session = await sessionStore.load();
      return _json({'account': session?.toJson()});
    }, appApiKey: appApiKey),
  );

  router.delete(
    '/',
    requireLocal((Request request) async {
      // Only the session file and the in-memory friend-request cache. See
      // this router's doc comment: logging out is not unfriending, and
      // FriendStore is never touched here.
      await sessionStore.clear();
      pendingRequests?.clear();
      return Response(204);
    }, appApiKey: appApiKey),
  );

  /// Everything below needs both a configured account service and a live
  /// session; resolving that once here keeps the four routes from each
  /// re-deriving it (and from drifting on which status they answer).
  /// Returns the logged-in accountId, or the [Response] to send instead.
  Future<(String?, Response?)> requireSession() async {
    if (accountService == null) {
      return (
        null,
        _error('No account service is configured for this node', status: 503),
      );
    }
    final session = await sessionStore.load();
    if (session == null) {
      return (
        null,
        // Not a 401: the caller is authorized, this node just isn't logged
        // in to anything. See this router's doc comment.
        _error('This node is not logged in to any account', status: 409),
      );
    }
    return (session.accountId, null);
  }

  router.get(
    '/friend-requests',
    requireLocal((Request request) async {
      final (accountId, failure) = await requireSession();
      if (failure != null) return failure;

      final fetched = await accountService!.pendingFriendRequestsOf(accountId!);
      // A failed fetch never overwrites what this node already had (see
      // [PendingFriendRequestCache]): the user sees the last real answer,
      // marked as not live, rather than an empty list or an error page.
      if (fetched != null) pendingRequests?.store(fetched);

      final snapshot =
          pendingRequests?.current ?? const PendingFriendRequests.empty();
      final requests = fetched ?? snapshot.requests;
      return _json({
        'requests': [for (final entry in requests) entry.toJson()],
        'fetchedAt': fetched != null
            ? DateTime.now().toUtc().toIso8601String()
            : snapshot.fetchedAt?.toIso8601String(),
        'live': fetched != null,
      });
    }, appApiKey: appApiKey),
  );

  router.post(
    '/friend-requests',
    requireLocal((Request request) async {
      final (accountId, failure) = await requireSession();
      if (failure != null) return failure;

      final Map<String, dynamic> body;
      try {
        body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      } on FormatException {
        return _error('Request body must be JSON');
      }

      final toUsername = body['toUsername'];
      if (toUsername is! String || toUsername.isEmpty) {
        return _error('"toUsername" is required');
      }

      final result = await accountService!.sendFriendRequest(
        accountId: accountId!,
        toUsername: toUsername,
      );
      if (!result.isSuccess) return _friendRequestFailureResponse(result);
      return _json(result.request!.toJson(), status: 201);
    }, appApiKey: appApiKey),
  );

  /// `accept` and `decline` differ by one boolean and one comment, so they
  /// share a handler rather than existing as two near-identical copies that
  /// could drift on error mapping or on whether they refresh.
  Handler respondHandler({required bool accept}) =>
      requireLocal((Request request) async {
        final requestId = request.params['requestId'];
        if (requestId == null || requestId.isEmpty) {
          return _error('"requestId" is required');
        }

        final (accountId, failure) = await requireSession();
        if (failure != null) return failure;

        final result = await accountService!.respondToFriendRequest(
          accountId: accountId!,
          requestId: requestId,
          accept: accept,
        );
        if (!result.isSuccess) return _friendRequestFailureResponse(result);

        // Awaited, like login's: on accept this is what puts the new friend
        // in `GET /api/v1/federation/friends` before this call returns; on
        // decline it is what drops the answered request from the cache. It
        // reconciles through `FriendStore.addFromAccountService`, so a
        // tombstoned account stays refused -- see this router's doc comment.
        await accountUpdates?.refreshNow(force: true);

        return _json(result.request!.toJson());
      }, appApiKey: appApiKey);

  router.post(
    '/friend-requests/<requestId>/accept',
    respondHandler(accept: true),
  );
  router.post(
    '/friend-requests/<requestId>/decline',
    respondHandler(accept: false),
  );

  return router;
}
