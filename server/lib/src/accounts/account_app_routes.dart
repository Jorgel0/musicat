import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../federation/account_friend_sync.dart';
import '../http/require_local.dart';
import 'account_service_client.dart';
import 'account_session_store.dart';

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
/// until the user removes them on purpose.
Router buildAccountAppRouter({
  required AccountSessionStore sessionStore,
  AccountServiceClient? accountService,
  FriendSyncService? friendSync,
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
      );
      if (!result.isSuccess) return _loginFailureResponse(result);

      final session = await sessionStore.save(
        accountId: result.accountId!,
        username: result.username!,
      );

      // Awaited, not fired and forgotten: by the time the app sees this
      // `200`, `GET /api/v1/federation/friends` already reflects the
      // account's accepted friendships, so the UI has nothing to poll for.
      // Bounded by `AccountServiceClient.timeout` and forced past
      // `minSyncInterval`, because a person pressing "log in" is exactly the
      // caller that must never be silently throttled. Its outcome is
      // deliberately not reported: a sync that failed leaves a perfectly
      // valid session behind, and the next one retries.
      await friendSync?.sync(force: true);

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
      // Only the session file. See this router's doc comment: logging out is
      // not unfriending, and FriendStore is never touched here.
      await sessionStore.clear();
      return Response(204);
    }, appApiKey: appApiKey),
  );

  return router;
}
