import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../federation/account_update_poller.dart';
import '../federation/friend_revocation.dart';
import '../federation/friend_store.dart';
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

Response _error(String message, {int status = 400, String? code}) =>
    _json({'error': message, 'code': ?code}, status: status);

/// The account service's own failure, translated into a status this node's
/// app can act on. Kept as one exhaustive switch rather than spread through
/// the route so adding an [AccountLoginOutcome] is a compile error here
/// instead of a silent `500`.
///
/// Each arm carries a fallback message *and* a fallback `code`, so the app
/// always gets something to branch on even when the answer came from an
/// account service too old to send one, or from this node itself (nothing
/// reached the service at all). The service's own code wins when there is
/// one, since it can be more specific than the outcome -- a `401` covers a
/// wrong password, an expired login nonce and a bad signature over it, and
/// only the service knows which.
Response _loginFailureResponse(AccountLoginResult result) {
  final (status, fallback, fallbackCode) = switch (result.outcome) {
    AccountLoginOutcome.wrongPassword => (
      401,
      'Incorrect password',
      'incorrect_password',
    ),
    AccountLoginOutcome.rateLimited => (
      429,
      'Too many failed attempts for this username. Try again later.',
      'rate_limited',
    ),
    AccountLoginOutcome.invalidUsername => (
      400,
      'Invalid username',
      'invalid_username',
    ),
    AccountLoginOutcome.noSuchAccount => (
      404,
      'No account with that username',
      'no_such_account',
    ),
    // Never a "try again" -- retrying is exactly what cannot help here. It
    // takes an operator untangling two accounts whose usernames differ only
    // in capitalization, so this must not be flattened into the `502` that
    // means "the service is up and broken, give it a minute".
    AccountLoginOutcome.ambiguousUsername => (
      409,
      'That username is held by two accounts that differ only in '
          'capitalization. Whoever runs the account service has to sort that '
          'out before either can be used.',
      'ambiguous_username',
    ),
    AccountLoginOutcome.serviceUnreachable => (
      503,
      'Could not reach the account service',
      'service_unreachable',
    ),
    AccountLoginOutcome.failed => (
      502,
      'The account service could not complete this login',
      'service_failed',
    ),
    // Unreachable: this function is only ever called for a failure.
    AccountLoginOutcome.created ||
    AccountLoginOutcome.linked => throw StateError('not a failure'),
  };
  // The service's own message when it sent one -- it is more specific than
  // anything guessable here (a `401` also covers an expired login nonce, not
  // just a wrong password), and it never contains anything the caller
  // submitted, so forwarding it can't echo a password back.
  return _error(
    result.error ?? fallback,
    status: status,
    code: result.code ?? fallbackCode,
  );
}

/// A friend-request action's failure, translated into a status this node's
/// app can act on -- the same exhaustive-switch shape (and the same reason
/// for it) as [_loginFailureResponse] above.
///
/// Each arm also carries a machine-readable `code`, for the same reason the
/// login path has had one since ADR 0053: a `503` from here is *either* "this
/// build has no account service at all" or "there is one and it did not
/// answer", and an app that cannot tell them apart has to guess between "set
/// a relay first" and "try again in a moment". [requireSession] emits
/// [_noAccountServiceCode] for the first; everything reaching this function
/// has an account service, so its `503` is always the second.
Response _friendRequestFailureResponse(FriendRequestActionResult result) {
  final (status, fallback, code) = switch (result.outcome) {
    FriendRequestActionOutcome.notFound => (404, 'Not found', 'not_found'),
    FriendRequestActionOutcome.forbidden => (
      403,
      'The account service refused this action',
      'forbidden',
    ),
    FriendRequestActionOutcome.conflict => (
      409,
      'That friend request has already been answered',
      'conflict',
    ),
    FriendRequestActionOutcome.invalid => (
      400,
      'Invalid friend request',
      'invalid_request',
    ),
    FriendRequestActionOutcome.serviceUnreachable => (
      503,
      'Could not reach the account service',
      'service_unreachable',
    ),
    FriendRequestActionOutcome.failed => (
      502,
      'The account service could not complete this action',
      'service_failed',
    ),
    // Unreachable: only ever called for a failure.
    FriendRequestActionOutcome.ok => throw StateError('not a failure'),
  };
  // The service's own message where it sent one: it is more specific than
  // anything guessable here ("Unknown username" versus "Unknown friend
  // request" are both 404s), and it never contains a credential.
  return _error(result.error ?? fallback, status: status, code: code);
}

/// This node was never pointed at an account service: accounts are not
/// available here at all, and no amount of retrying changes that.
///
/// Told apart from [_serviceUnreachableCode] everywhere, because they need
/// opposite things from a person -- configuration versus patience -- and both
/// arrive as `503`. `GET /api/v1/account`'s `accountsAvailable` is how an app
/// asks the same question without provoking a failure first.
const String _noAccountServiceCode = 'no_account_service';

/// There is an account service configured, and this node could not reach it.
const String _serviceUnreachableCode = 'service_unreachable';

/// The account service answered, but with something unusable.
const String _serviceFailedCode = 'service_failed';

/// This node has an account service but is not logged in to any account. Not
/// a `401`: the caller is authorized, this node has nobody to act as.
const String _notLoggedInCode = 'not_logged_in';

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
/// **`allowCreate` (optional, `true` when absent)**: with `false`, a username
/// nobody holds is answered `404` instead of being signed up, so an app can
/// ask "create a new account?" rather than turning a typo into a second,
/// empty account. Absent means `true`, which is exactly what this route has
/// always done.
///
/// **Every failure from this route carries a machine-readable `code` beside
/// its human `error`**, because the status alone is ambiguous in two places:
/// `400` is both an invalid username and a too-short password, and `503` is
/// both "no account service configured" and "couldn't reach it". Branch on
/// `code`, show `error`. The full set:
///
/// | status | code | means |
/// |---|---|---|
/// | 400 | `invalid_request` | this request was malformed (missing field, wrong type) |
/// | 400 | `invalid_username` | the username doesn't match the format rule |
/// | 400 | `password_too_short` | creating an account, password under the service's minimum (named in `error`) |
/// | 401 | `incorrect_password` | wrong password |
/// | 401 | `login_expired` | the login nonce expired mid-handshake; retrying works |
/// | 401 | `invalid_login_proof` | this node's own signature didn't check out |
/// | 404 | `no_such_account` | `allowCreate: false` and nobody holds that username |
/// | 409 | `ambiguous_username` | two accounts differ only by case; an operator must fix it, retrying cannot |
/// | 429 | `rate_limited` | too many wrong passwords for this username |
/// | 429 | `too_many_new_accounts` | too many accounts created from this address |
/// | 502 | `service_failed` | the account service answered unusably |
/// | 503 | `no_account_service` | this node has none configured |
/// | 503 | `service_unreachable` | it has one and could not reach it |
///
/// `GET /` — `{"account": {accountId, username, loggedInAt} | null,
/// "accountsAvailable": bool}`, always `200`. A `null` field rather than a
/// `404` is how this API already says "nothing here" for a single optional
/// thing (`GET /api/v1/soulseek/downloads-directory` answers
/// `{"directory": ... | null}` the same way), and it keeps "not logged in"
/// distinguishable from "that route doesn't exist" without the app having to
/// special-case a status. Answered from local disk: reading who you are must
/// not need the account service (Rule 1).
///
/// **`accountsAvailable` is the capability signal ADR 0053 left open**, and
/// it is additive — `account` is unchanged in name, shape and meaning. It is
/// `false` on a node started with no `accountServiceUrl`, where
/// `{"account": null}` never meant "sign in" but "there is nothing here to
/// sign in to", and the app previously had to guess which. It says nothing
/// about whether that service is reachable *right now* (this route makes no
/// network call, ever); the routes that do call it report that through their
/// `code`, `service_unreachable` versus `no_account_service`.
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
/// `GET /friend-requests` — the still-pending requests this account is on
/// either side of, as `{requests: [...], outgoing: [...], fetchedAt, live}`.
/// Fetches live from the account service and refreshes [pendingRequests] on
/// the way past; if that fetch fails, answers `200` with the last snapshot
/// this node holds and `live: false` instead of an error, so a dead relay
/// degrades to a slightly stale list rather than a broken screen. `fetchedAt`
/// is `null` exactly when this node has *never* successfully fetched, which
/// is the one case an app must not render as "no friend requests". Each entry
/// is verbatim what the account service returned (see [AccountFriendRequest])
/// — notably including `fromUsername`/`toUsername`, since an accountId is not
/// something to show a human.
///
/// **`outgoing` is additive**: `requests` keeps its exact existing meaning
/// (the ones addressed *to* this account), and an app that ignores the new
/// key behaves exactly as before. Both lists come from one upstream request
/// (`direction=both`), so a poll costs what it always did and the single
/// `live`/`fetchedAt` pair describes both honestly — two separate fetches
/// would have let one list be older than the other while claiming otherwise.
/// Against an account service too old to know `direction`, `outgoing` comes
/// back empty rather than the call failing.
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
/// `POST /friend-requests/<id>/cancel` — withdraws one *this* account sent;
/// `200` with the updated request, whose `status` is now `cancelled`. Only
/// the sender may (the account service enforces it: `403` otherwise), and
/// only while it is still pending (`409` once answered — a request the other
/// side accepted is a friendship, and ending one of those is
/// `DELETE /api/v1/federation/friends/<nodeId>`). Refreshes like decline, so
/// the withdrawn request is out of `outgoing` by the time the app sees the
/// response. It deliberately has **no local effect at all** beyond that: it
/// is the undo of a send, not a decision to remove anybody, so it writes no
/// tombstone.
///
/// ## Devices (this account's linked devices)
///
/// `GET /devices` — `{devices: [{nodeId, publicKeyBase64, linkedAt, relayUrl,
/// deviceName, isThisDevice}, ...]}`, fetched live from the account service.
/// `409`/`503` on no session/no account service like the friend-request
/// routes; `503 service_unreachable` if the service didn't answer and `502`
/// if it answered unusably. Nothing is cached: a stale list is a bad basis
/// for deciding what to revoke, so this fails honestly instead.
/// `deviceName` is the platform the node reported at its last login and may
/// be `null`; `isThisDevice` is added here, since the account service cannot
/// know which of the rows is asking.
///
/// `DELETE /devices/<nodeId>` — unlinks one; `200 {"signedOut": bool}`. This
/// is the recovery path for a lost or stolen device that ADR 0048 shipped and
/// nothing could reach.
///
/// **Unlinking the device you are on is allowed, and signs this node out**
/// (`signedOut: true`), clearing the local session and the cached friend
/// requests, but *never* the friend list — same rule as `DELETE
/// /api/v1/account`. Refusing it was the alternative and is worse in both
/// directions: it would make "remove this device from my account" impossible
/// from the only device somebody has (the phone they are about to sell), and
/// allowing it *without* clearing the session would leave this node believing
/// it acts for an account that no longer knows it, so every signed call would
/// quietly `401` with nothing on screen to explain why. A body rather than a
/// `204` precisely so the app never has to infer which of the two happened.
///
/// The unlinked device itself is **not** told. Its own next sync simply
/// starts failing, and it finds out at its next
/// `GET /api/v1/account/devices`, which is an acceptable gap for a device you
/// are revoking *because* you no longer control it.
///
/// **Sending or accepting a friend request forgets any local removal of that
/// person** (`adoptExplicitly` below), which is a correction of what this
/// comment used to claim. It previously said Rule 2 had no exception here and
/// that accepting could never resurrect somebody this device had removed —
/// true of the code, and the wrong behaviour: the refresh goes through
/// [FriendStore.addFromAccountService], which refuses a tombstoned account
/// inside its lock, so accepting a request from someone you had unfriended
/// answered `200`, told the user "you are now friends", and changed nothing
/// locally, with no error and no way back except pairing by code — the exact
/// tedium Fase 5 exists to remove. Rule 2 is that **no later *sync* may
/// resurrect a removal**, and a person tapping Accept is not a sync. Every
/// sync path still refuses a tombstoned account, unchanged and still tested;
/// only these two explicitly-chosen-by-name actions clear one, and they add
/// no friend themselves — the ordinary sync does that, one line later, with
/// nothing left for it to refuse.
///
/// The same two actions also cancel any revocation this node still owes for
/// that account, so making up with somebody you unfriended offline cannot end
/// with the queue telling the account service otherwise once the network
/// comes back (see [FriendRevocationService.cancel]).
///
/// [pendingRequests], [accountUpdates] and [revocations] are all optional so
/// this router can still be built (and still answer `GET`/`DELETE /`) on a
/// node with no account service at all. [friendStore] is not: this node
/// always has one, and the local half of an accept must not depend on
/// remembering to pass it. Neither is [nodeId], this node's own device
/// identifier: it is what `GET /devices` marks `isThisDevice` with and what
/// `DELETE /devices/<nodeId>` recognizes as a self-unlink, and defaulting it
/// to anything would make both of those quietly wrong rather than fail to
/// compile.
Router buildAccountAppRouter({
  required String nodeId,
  required AccountSessionStore sessionStore,
  required FriendStore friendStore,
  AccountServiceClient? accountService,
  AccountUpdatePoller? accountUpdates,
  PendingFriendRequestCache? pendingRequests,
  FriendRevocationService? revocations,
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
          // Told apart from `service_unreachable` on purpose: one is a node
          // that was never pointed at an account service, the other is one
          // that was and can't reach it, and only the second is worth
          // retrying.
          code: 'no_account_service',
        );
      }

      final Map<String, dynamic> body;
      try {
        body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      } on FormatException {
        return _error('Request body must be JSON', code: 'invalid_request');
      }

      final username = body['username'];
      final password = body['password'];
      final allowCreate = body['allowCreate'];
      if (username is! String || username.isEmpty) {
        return _error('"username" is required', code: 'invalid_request');
      }
      if (password is! String || password.isEmpty) {
        return _error('"password" is required', code: 'invalid_request');
      }
      if (allowCreate != null && allowCreate is! bool) {
        return _error(
          '"allowCreate" must be a boolean if present',
          code: 'invalid_request',
        );
      }

      final result = await accountService.login(
        username: username,
        password: password,
        // Absent means `true`, which is what this route has always done --
        // an app that knows nothing about the flag behaves exactly as
        // before. See this router's doc comment.
        allowCreate: allowCreate as bool? ?? true,
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
      return _json({
        'account': session?.toJson(),
        // Purely additive: the existing `account` field keeps its exact
        // meaning and its exact shape. Before this, `{"account": null}` was
        // the answer both for "signed out" and for "this build has no account
        // service at all", so an app had to guess between "sign in" and "there
        // is nothing to sign in to" -- ADR 0053 flagged that as open.
        //
        // A configuration fact, not a reachability one: this route reads local
        // disk and nothing else (Rule 1), so it says whether accounts exist
        // *here*, never whether the service is up right now. Finding that out
        // is what the routes that actually call it are for.
        'accountsAvailable': accountService != null,
      });
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
        _error(
          'No account service is configured for this node',
          status: 503,
          // The distinction ADR 0053 left open: this `503` and the one for an
          // account service that did not answer are the same status and
          // opposite problems. See [_noAccountServiceCode].
          code: _noAccountServiceCode,
        ),
      );
    }
    final session = await sessionStore.load();
    if (session == null) {
      return (
        null,
        // Not a 401: the caller is authorized, this node just isn't logged
        // in to anything. See this router's doc comment.
        _error(
          'This node is not logged in to any account',
          status: 409,
          code: _notLoggedInCode,
        ),
      );
    }
    return (session.accountId, null);
  }

  /// The local half of an explicit "yes, this person" -- sending someone a
  /// friend request, or accepting theirs. Both are the user acting on a name
  /// they chose, which is precisely what a tombstone is not allowed to
  /// override.
  ///
  /// Two purely local, instant, offline-safe effects, and no others:
  ///
  /// - **Forgets any removal of [friendAccountId].** Without this, the sync
  ///   that runs a moment later goes through
  ///   [FriendStore.addFromAccountService], which refuses a tombstoned
  ///   account inside its own lock, and the whole thing no-ops in silence:
  ///   the account service returns `200`, the app says "you are now
  ///   friends", and locally nothing has happened, with no way back but the
  ///   pairing-code dance accounts exist to replace. Rule 2 is "no later
  ///   *sync* may resurrect a removal", and a person tapping Accept is not a
  ///   sync -- every sync path still refuses, unchanged.
  /// - **Cancels any revocation still queued for them.** Unfriending while
  ///   offline queues one; making up before it drains would otherwise
  ///   deliver "we are not friends" for a friendship that is live again,
  ///   ending it on the other side only. See [FriendRevocationService.cancel].
  ///
  /// Deliberately nothing else: it does not add a friend, which stays the
  /// sync's job through the one path that knows all the rules.
  Future<void> adoptExplicitly(String friendAccountId) async {
    await friendStore.forgetRemoval(friendAccountId);
    await revocations?.cancel([friendAccountId]);
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
      if (fetched != null) {
        pendingRequests?.store(fetched.incoming, outgoing: fetched.outgoing);
      }

      final snapshot =
          pendingRequests?.current ?? const PendingFriendRequests.empty();
      final requests = fetched?.incoming ?? snapshot.requests;
      final outgoing = fetched?.outgoing ?? snapshot.outgoing;
      return _json({
        'requests': [for (final entry in requests) entry.toJson()],
        // Additive, and from the *same* fetch as `requests` above -- so the
        // one `live`/`fetchedAt` pair honestly describes both lists, and an
        // app showing "waiting on them" beside "they are waiting on you" is
        // never mixing two different moments.
        'outgoing': [for (final entry in outgoing) entry.toJson()],
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
      await adoptExplicitly(result.request!.toAccountId);
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

        // Before the refresh, and only on accept. The account service only
        // lets a request's *recipient* answer it, so on success `<me>` is
        // the recipient and the new friend is always the sender.
        if (accept) await adoptExplicitly(result.request!.fromAccountId);

        // Awaited, like login's: on accept this is what puts the new friend
        // in `GET /api/v1/federation/friends` before this call returns; on
        // decline it is what drops the answered request from the cache. It
        // reconciles through `FriendStore.addFromAccountService`, which
        // refuses a tombstoned account -- which is why the line above runs
        // first. See this router's doc comment.
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

  router.post(
    '/friend-requests/<requestId>/cancel',
    requireLocal((Request request) async {
      final requestId = request.params['requestId'];
      if (requestId == null || requestId.isEmpty) {
        return _error('"requestId" is required', code: 'invalid_request');
      }

      final (accountId, failure) = await requireSession();
      if (failure != null) return failure;

      final result = await accountService!.cancelFriendRequest(
        accountId: accountId!,
        requestId: requestId,
      );
      if (!result.isSuccess) return _friendRequestFailureResponse(result);

      // Deliberately *not* wrapped in `adoptExplicitly`, unlike send and
      // accept. Cancelling is the undo of a send, and undoing a send is not a
      // decision to remove anybody: it must not write a tombstone, and there
      // is nothing to forget either (the send already cleared any removal,
      // and re-tombstoning here would silently break a later re-send).
      //
      // Refreshed like decline, so the withdrawn request is out of this
      // node's cached outgoing list by the time the app sees this response
      // rather than up to a poll interval later.
      await accountUpdates?.refreshNow(force: true);

      return _json(result.request!.toJson());
    }, appApiKey: appApiKey),
  );

  router.get(
    '/devices',
    requireLocal((Request request) async {
      final (accountId, failure) = await requireSession();
      if (failure != null) return failure;

      final fetched = await accountService!.fetchDevicesOf(accountId!);
      // No cached fallback here, unlike the friend-request list: nothing
      // stores a device list, and inventing a stale one for a screen whose
      // whole purpose is deciding what to revoke would be worse than saying
      // "ask again in a moment". The two `503`s stay distinguishable by
      // `code`.
      if (!fetched.reachable) {
        return _error(
          'Could not reach the account service',
          status: 503,
          code: _serviceUnreachableCode,
        );
      }
      final devices = fetched.devices;
      if (devices == null) {
        return _error(
          'The account service could not list this account\'s devices',
          status: 502,
          code: _serviceFailedCode,
        );
      }

      return _json({
        'devices': [
          for (final device in devices)
            {
              ...device.toJson(),
              // The one fact the account service cannot know and the app
              // must not have to derive: which row is the device asking.
              // Without it the UI cannot warn that removing *this* one signs
              // you out here, which is the whole confusing case.
              'isThisDevice': device.nodeId == nodeId,
            },
        ],
      });
    }, appApiKey: appApiKey),
  );

  router.delete(
    '/devices/<targetNodeId>',
    requireLocal((Request request) async {
      final targetNodeId = request.params['targetNodeId'];
      if (targetNodeId == null || targetNodeId.isEmpty) {
        return _error('"nodeId" is required', code: 'invalid_request');
      }

      final (accountId, failure) = await requireSession();
      if (failure != null) return failure;

      final outcome = await accountService!.unlinkDevice(
        accountId: accountId!,
        nodeId: targetNodeId,
      );
      switch (outcome) {
        case UnlinkDeviceOutcome.unreachable:
          return _error(
            'Could not reach the account service',
            status: 503,
            code: _serviceUnreachableCode,
          );
        case UnlinkDeviceOutcome.refused:
          return _error(
            'The account service refused to unlink that device',
            status: 403,
            code: 'forbidden',
          );
        case UnlinkDeviceOutcome.failed:
          return _error(
            'The account service could not unlink that device',
            status: 502,
            code: _serviceFailedCode,
          );
        case UnlinkDeviceOutcome.unlinked:
          break;
      }

      // Unlinking the device you are standing on is allowed, and the local
      // session goes with it -- see this router's doc comment for why
      // refusing would have been the worse of the two options. Strictly
      // *after* the service confirmed: clearing first and then failing would
      // sign someone out of an account whose device list still lists them.
      //
      // Friends are untouched, exactly as `DELETE /api/v1/account` leaves
      // them: this ends a device's authority to act for the account, and
      // local trust established by pairing was never that account's to
      // revoke.
      final signedOut = targetNodeId == nodeId;
      if (signedOut) {
        await sessionStore.clear();
        pendingRequests?.clear();
      }
      return _json({'signedOut': signedOut});
    }, appApiKey: appApiKey),
  );

  return router;
}
