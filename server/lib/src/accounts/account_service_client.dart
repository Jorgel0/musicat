import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../federation/request_signing.dart';
import '../identity/node_identity.dart';
import 'account.dart';

/// How [AccountServiceClient.login] ended.
///
/// [created] and [linked] are both successes and mirror the account
/// service's own [LoginOutcome] names exactly (`account_store.dart`): a
/// brand-new username created an account with this device as its first,
/// versus an existing one that verified the password and linked this device
/// as an additional one. The remaining values are the failures a *user*
/// needs told apart, which is the whole reason this isn't a nullable
/// accountId.
enum AccountLoginOutcome {
  created,
  linked,

  /// The account service answered `401`. Almost always a wrong password --
  /// but the same status also covers an expired/already-redeemed login nonce
  /// and a bad signature over it, neither of which this client can produce
  /// on its own (it performs both halves of the handshake back to back with
  /// its own key). [AccountLoginResult.error] carries the service's own
  /// message so a caller can surface the accurate one rather than guessing.
  wrongPassword,

  /// `429`: too many consecutive wrong passwords for this username, which
  /// the account service locks out for a while (ADR 0048).
  rateLimited,

  /// `400`: the account service refused the credentials themselves. Two
  /// shapes reach it, both only on signup -- the username format rule shared
  /// with the username directory (`usernamePattern`), and a new password
  /// shorter than the service's minimum. They are one outcome because they
  /// need one response from the app (show the service's own message and let
  /// the user fix it); [AccountLoginResult.error] is what tells them apart
  /// in words.
  invalidUsername,

  /// `404`: no account holds this username, and the caller asked not to
  /// create one (`allowCreate: false`). The signal an app uses to ask "create
  /// a new account?" instead of silently making one out of a typo.
  noSuchAccount,

  /// `409`: two accounts on the service hold this username in different
  /// cases (only possible in data written before usernames were
  /// case-insensitive), and it refuses to guess which one the caller means.
  ///
  /// **Deliberately not folded into [failed].** Retrying cannot help and no
  /// amount of waiting changes it -- an operator has to fix `accounts.json`
  /// -- so telling the user "the service is having a moment, try again" would
  /// be the one piece of advice guaranteed to be useless. That is precisely
  /// the point of detecting the collision instead of silently shadowing one
  /// of the two accounts: somebody has to be told.
  ambiguousUsername,

  /// The account service never answered at all: connection refused, DNS
  /// failure, or [AccountServiceClient.timeout] elapsed. A condition of the
  /// service, not of the credentials -- retrying later is the right advice.
  serviceUnreachable,

  /// The service answered, but with something this client can't act on (a
  /// `5xx`, an unexpected status, an unparseable body). Distinct from
  /// [serviceUnreachable] because "it's down, try later" and "it's up and
  /// broken" are different things to tell a user, and different things to
  /// debug.
  failed,
}

/// The outcome of [AccountServiceClient.login].
///
/// [accountId]/[username] are non-null exactly when [isSuccess] is true.
/// **[password] is deliberately nowhere on this class**, or anywhere else
/// that outlives the call: see [AccountSession]'s doc comment for why this
/// device authenticates with its own node key from here on.
class AccountLoginResult {
  const AccountLoginResult._(
    this.outcome, {
    this.accountId,
    this.username,
    this.error,
    this.code,
  });

  const AccountLoginResult.created({
    required String accountId,
    required String username,
  }) : this._(
         AccountLoginOutcome.created,
         accountId: accountId,
         username: username,
       );

  const AccountLoginResult.linked({
    required String accountId,
    required String username,
  }) : this._(
         AccountLoginOutcome.linked,
         accountId: accountId,
         username: username,
       );

  const AccountLoginResult.failure(
    AccountLoginOutcome outcome, {
    String? error,
    String? code,
  }) : this._(outcome, error: error, code: code);

  final AccountLoginOutcome outcome;
  final String? accountId;

  /// The username the account service echoed back -- the canonical spelling
  /// of it, rather than whatever the caller typed.
  final String? username;

  /// The account service's own `{"error": ...}` message, when it sent one.
  /// Never contains anything the caller submitted (the account service never
  /// echoes a password back), so it is safe to forward to the app.
  final String? error;

  /// The account service's own machine-readable `code` beside that message
  /// (`account_routes.dart`'s login codes), or `null` from a service too old
  /// to send one. This is what a caller should *branch* on -- notably to tell
  /// the two `400`s apart, an invalid username from a too-short password --
  /// instead of matching on [error]'s wording, which is prose and may be
  /// rewritten at any time.
  final String? code;

  bool get isSuccess =>
      outcome == AccountLoginOutcome.created ||
      outcome == AccountLoginOutcome.linked;

  /// Whether this login *created* the account, as opposed to linking this
  /// device to one that already existed -- the one bit of a successful login
  /// the app genuinely needs (it is the difference between "welcome" and
  /// "welcome back", and between a friend list that is empty because it is
  /// new and one that is empty because the sync failed).
  bool get created => outcome == AccountLoginOutcome.created;
}

/// How a friend-request *action* against the account service ended --
/// [AccountServiceClient.sendFriendRequest] and
/// [AccountServiceClient.respondToFriendRequest].
///
/// Not collapsed to a nullable result, unlike [AccountServiceClient.devicesOf]
/// and friends, and for the same reason [AccountLoginOutcome] isn't: a person
/// is waiting. "There is nobody with that username", "that request is already
/// accepted" and "the account service is down" ask three different things of
/// them, and one `null` would force the route above to invent a single wrong
/// message for all three.
enum FriendRequestActionOutcome {
  ok,

  /// `404`: no such username (when sending), or no such friend request (when
  /// responding).
  notFound,

  /// `403`: the account service refused this account the action -- notably,
  /// only a request's *recipient* may accept or decline it.
  forbidden,

  /// `409`: the request has already been accepted or declined the other way.
  conflict,

  /// `400`: the service rejected the request itself (e.g. befriending
  /// yourself). [FriendRequestActionResult.error] carries its own wording.
  invalid,

  /// Never answered at all: connection refused, DNS failure, or
  /// [AccountServiceClient.timeout] elapsed.
  serviceUnreachable,

  /// Answered with something unusable -- a `5xx`, an unexpected status, or a
  /// body this client couldn't parse.
  failed,
}

/// The outcome of one friend-request action. [request] is non-null exactly
/// when [outcome] is [FriendRequestActionOutcome.ok] *and* the service
/// returned a request body (both `send` and `accept`/`decline` do).
class FriendRequestActionResult {
  const FriendRequestActionResult(this.outcome, {this.request, this.error});

  final FriendRequestActionOutcome outcome;
  final AccountFriendRequest? request;

  /// The account service's own `{"error": ...}` message, when it sent one --
  /// safe to forward to the app: it never echoes anything the caller
  /// submitted beyond a username the caller typed itself.
  final String? error;

  bool get isSuccess => outcome == FriendRequestActionOutcome.ok;
}

/// How [AccountServiceClient.revokeFriendship] ended -- three outcomes rather
/// than a `bool`, because the caller
/// (`federation/friend_revocation.dart`) has to decide between "done, forget
/// it", "this will never work, stop trying" and "try again later", and those
/// are three different things.
enum RevokeFriendshipOutcome {
  /// `204`: the account service applied it, or had already applied it
  /// (the route is idempotent). Either way there is nothing left owed.
  revoked,

  /// The service answered, and answered definitively **no** -- a `403` (this
  /// node's device isn't linked to the account it claims), a `404` (an
  /// account service too old to have this route at all), or any other `4xx`
  /// that isn't [failed]'s. Retrying reproduces it exactly, so the queued
  /// revocation is dropped rather than retried for days.
  refused,

  /// Anything that might succeed later: never answered at all (connection
  /// refused, DNS failure, [AccountServiceClient.timeout]), a `5xx`, a
  /// `429`, or a `401`. `401` is deliberately in this bucket and not
  /// [refused]: the account service rejects a signed request whose timestamp
  /// is more than five minutes off (`AccountRequestVerifier`), and a phone
  /// with a bad clock that later corrects itself must not have silently
  /// thrown its pending revocations away.
  failed,
}

/// How [AccountServiceClient.unlinkDevice] ended.
///
/// Four outcomes rather than a `bool` for the same reason
/// [RevokeFriendshipOutcome] has three: the caller is a person who pressed
/// "remove this device" and is waiting, and "done", "the service says no",
/// "the service is down" and "the service is broken" ask different things of
/// them. Getting this wrong here is worse than elsewhere -- this is the
/// recovery path for a lost or stolen device, and "it didn't work" reported
/// as "done" would leave someone believing they had revoked a phone they
/// hadn't.
enum UnlinkDeviceOutcome {
  /// `204`: unlinked, or already was (the route is idempotent).
  unlinked,

  /// The service answered and refused -- a `401`/`403` (this node's own
  /// device isn't linked to the account it claims), or any other `4xx`.
  /// Retrying reproduces it exactly.
  refused,

  /// Never answered at all: connection refused, DNS failure, or
  /// [AccountServiceClient.timeout] elapsed. Worth retrying; nothing has
  /// been unlinked.
  unreachable,

  /// Answered with something unusable -- a `5xx` or an unexpected status.
  failed,
}

/// This device's own platform, as [DeviceLink.deviceName] -- the only thing a
/// node truthfully knows about itself that helps a human pick it out of a
/// device list.
///
/// Deliberately **not** `Platform.localHostname`, which is the obvious
/// alternative and frequently somebody's own name: this value is disclosed to
/// every mutual friend (see [DeviceLink.deviceName]), and a platform label is
/// the least identifying thing that still answers "which of these is my old
/// phone?".
///
/// An unrecognized platform is reported verbatim rather than as "unknown" --
/// it is already a short lowercase ASCII token from `dart:io`, and a name
/// that says `fuchsia` is more use than one that says nothing.
String defaultDeviceName() => switch (Platform.operatingSystem) {
  'android' => 'Android',
  'ios' => 'iOS',
  'linux' => 'Linux',
  'macos' => 'macOS',
  'windows' => 'Windows',
  final other => other,
};

/// A Musicat Server's *client* for the account service (`account_routes.dart`,
/// hosted on the relay process, ADR 0048) — the only code in a node that
/// talks to it.
///
/// Deliberately kept as its own injectable collaborator rather than folded
/// into anything on the request-serving path: an already-logged-in device
/// has to keep working with this service unreachable (verification from the
/// local cache, sharing over the local network), so everything that needs
/// it must be reachable *only* from a cache-miss or a scheduled refresh —
/// see `federation/unknown_device_resolver.dart`.
///
/// Authenticates as this node's own device by signing each request with its
/// existing Ed25519 identity, the exact shape `AccountRequestVerifier`
/// checks (`X-Node-Id`/`X-Timestamp`/`X-Signature` over
/// [canonicalRequestString]) — no session token, and no account state
/// stored locally: the account service resolves which account is calling
/// from the signing device's nodeId.
class AccountServiceClient {
  AccountServiceClient({
    required String baseUrl,
    required this.identity,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 5),
    String? deviceName,
  }) : baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       deviceName = deviceName ?? defaultDeviceName(),
       _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// The account service's own base URL, e.g.
  /// `http://relay.example.com:8090/accounts` — the relay's HTTP origin
  /// plus the prefix `bin/relay.dart` mounts the account router at. Any
  /// trailing slash is normalized away.
  final String baseUrl;

  final NodeIdentity identity;

  /// What this node calls itself in its own account's device list, published
  /// at every login and nowhere else (see [DeviceLink.deviceName]). Defaults
  /// to [defaultDeviceName]; a parameter only so tests are not at the mercy
  /// of which platform they run on.
  final String deviceName;

  /// Bounds every call: this service is never on a hot path, but a hung
  /// connection to it must not hold anything else up either.
  final Duration timeout;

  final http.Client _client;
  final bool _ownsClient;

  /// Logs this node's own device in to [username], creating the account if
  /// that username is free -- the account service's `POST /login/start` then
  /// `POST /login/complete` handshake, signed with **this node's own
  /// identity** (see `account_routes.dart` for the authoritative contract).
  ///
  /// The two steps are: ask for a fresh single-use nonce, then send
  /// `{username, password, nodeId, publicKeyBase64, signatureOverNonce}`
  /// where the signature is this node's Ed25519 signature over the nonce
  /// bytes. That signature is what makes the resulting device link
  /// self-certifying: from here on this device proves it acts for the
  /// account by signing with the same key, and needs no session token.
  ///
  /// [password] is used for exactly this one request and then dropped. It is
  /// never stored, never returned in [AccountLoginResult], never logged, and
  /// never put in a URL (it goes in the request body precisely because
  /// `logRequests()` and every proxy in between record paths and query
  /// strings but not bodies).
  ///
  /// [allowCreate] defaults to `true` -- what this method has always done.
  /// Passing `false` asks the account service to answer
  /// [AccountLoginOutcome.noSuchAccount] instead of creating an account for a
  /// username nobody holds, which is how an app turns a typo into a question
  /// rather than into a second, empty account.
  ///
  /// [relayUrl] is this node's own currently-connected relay endpoint, if it
  /// has one, and login is the *only* place it is ever published: the account
  /// service records it against this device (see [DeviceLink.relayUrl]) so
  /// that friends made purely through friend requests have some way to reach
  /// this node at all. Omitting it means "I have no relay", and clears any
  /// endpoint previously recorded for this device. It is deliberately not
  /// something this client refreshes on its own schedule — a node that
  /// changes relays publishes that by logging in again, which is also the
  /// only moment its user is present to consent to the disclosure.
  ///
  /// **Unlike [accountIdForDevice] and [devicesOf], this does not collapse
  /// its failures into `null`, and that inconsistency is deliberate.** Those
  /// two exist to *refresh a cache*, and every way they can fail has the
  /// same correct response -- leave the cache alone -- so giving their
  /// callers any more detail would only be an invitation to act on it
  /// wrongly. This one is driven by a person who typed a password and is
  /// waiting: "wrong password", "locked out for a minute", "the server is
  /// down" and "the server is broken" demand four different things of them,
  /// and a `null` would force the route above to invent a single wrong
  /// message for all four. See [AccountLoginOutcome].
  Future<AccountLoginResult> login({
    required String username,
    required String password,
    String? relayUrl,
    bool allowCreate = true,
  }) async {
    final List<int> nonce;
    try {
      final start = await _client
          .post(
            Uri.parse('$baseUrl/login/start'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'username': username}),
          )
          .timeout(timeout);
      if (start.statusCode != 200) {
        return AccountLoginResult.failure(
          AccountLoginOutcome.failed,
          error: _errorMessageOf(start),
        );
      }
      final body = jsonDecode(start.body) as Map<String, dynamic>;
      nonce = base64Decode(body['nonceBase64'] as String);
    } on Exception catch (error) {
      // A transport failure and a malformed/garbage response are told apart
      // here rather than lumped together: only the former means "try again
      // later", and only it should be reported as the service being down.
      return AccountLoginResult.failure(
        error is FormatException || error is TypeError
            ? AccountLoginOutcome.failed
            : AccountLoginOutcome.serviceUnreachable,
        error: 'Could not start a login with the account service',
      );
    }

    final signature = await identity.sign(nonce);

    final http.Response complete;
    try {
      complete = await _client
          .post(
            Uri.parse('$baseUrl/login/complete'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'username': username,
              'password': password,
              'nodeId': identity.nodeId,
              'publicKeyBase64': await identity.publicKeyBase64(),
              'signatureOverNonce': base64Encode(signature),
              // Omitted entirely (not sent as null) when this node has no
              // relay, so an older account service that doesn't know this
              // field sees the exact request it always did.
              if (relayUrl != null && relayUrl.isNotEmpty) 'relayUrl': relayUrl,
              // Same "omit rather than send null" rule as relayUrl above, so
              // an account service too old to know this field sees exactly
              // the request it always did.
              if (deviceName.isNotEmpty) 'deviceName': deviceName,
              // Same rule: only sent when it is not the default, so a
              // request that allows creation is byte-for-byte the one this
              // client has always sent. An account service too old to know
              // the field would ignore it and create the account anyway --
              // which is why this is a *first* call the app follows up, not
              // a guarantee it relies on.
              if (!allowCreate) 'allowCreate': false,
            }),
          )
          .timeout(timeout);
    } catch (_) {
      return const AccountLoginResult.failure(
        AccountLoginOutcome.serviceUnreachable,
        error: 'Could not reach the account service',
      );
    }

    // Everything from here on is the service having answered, so a rejection
    // is never reported as it being down.
    final message = _errorMessageOf(complete);
    final code = _errorCodeOf(complete);
    switch (complete.statusCode) {
      case 429:
        return AccountLoginResult.failure(
          AccountLoginOutcome.rateLimited,
          error: message,
          code: code,
        );
      case 401:
        return AccountLoginResult.failure(
          AccountLoginOutcome.wrongPassword,
          error: message,
          code: code,
        );
      case 400:
        return AccountLoginResult.failure(
          AccountLoginOutcome.invalidUsername,
          error: message,
          code: code,
        );
      case 404:
        return AccountLoginResult.failure(
          AccountLoginOutcome.noSuchAccount,
          error: message,
          code: code,
        );
      case 409:
        return AccountLoginResult.failure(
          AccountLoginOutcome.ambiguousUsername,
          error: message,
          code: code,
        );
      case 200:
      case 201:
        try {
          final body = jsonDecode(complete.body) as Map<String, dynamic>;
          final accountId = body['accountId'] as String;
          final canonicalUsername = body['username'] as String;
          return complete.statusCode == 201
              ? AccountLoginResult.created(
                  accountId: accountId,
                  username: canonicalUsername,
                )
              : AccountLoginResult.linked(
                  accountId: accountId,
                  username: canonicalUsername,
                );
        } catch (_) {
          return const AccountLoginResult.failure(
            AccountLoginOutcome.failed,
            error: 'The account service returned a malformed login response',
          );
        }
      default:
        return AccountLoginResult.failure(
          AccountLoginOutcome.failed,
          error: message,
          code: code,
        );
    }
  }

  /// The account service's own `{"error": ...}` message from [response], or
  /// `null` if it didn't send one in that shape. Never includes the raw body
  /// as a fallback: an unexpected body could be anything at all, and this
  /// value is forwarded to the app.
  String? _errorMessageOf(http.Response response) =>
      _errorFieldOf(response, 'error');

  /// The account service's own machine-readable `{"code": ...}`, or `null`
  /// from an older service (or any route that doesn't send one -- only the
  /// login path does).
  String? _errorCodeOf(http.Response response) =>
      _errorFieldOf(response, 'code');

  String? _errorFieldOf(http.Response response, String field) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) return body[field] as String?;
    } catch (_) {
      // Deliberately silent: a non-JSON body just means there's nothing here.
    }
    return null;
  }

  /// Every account [accountId] currently has an accepted friend request
  /// with, each with its device list -- `GET <baseUrl>/<accountId>/friends`,
  /// signed as this node's own device.
  ///
  /// `null` on any failure at all: an unreachable service, a `403` (this
  /// node's device isn't linked to [accountId]), or an unparseable response.
  /// Collapsed exactly like [devicesOf] and for the same reason -- the only
  /// caller is [FriendSyncService], and every one of those means the same
  /// thing to it: leave the local friend list exactly as it is. A friend
  /// list is never *partially* applied.
  ///
  /// An empty list, by contrast, is a real answer ("you have no friends
  /// yet") and is distinct from `null` -- though the sync treats them the
  /// same anyway, since it never removes a local friend.
  Future<List<AccountFriend>?> friendsOf(String accountId) async {
    final uri = Uri.parse('$baseUrl/${Uri.encodeComponent(accountId)}/friends');
    try {
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'GET', path: uri.path);
      final response = await _client
          .get(uri, headers: headers)
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as List<dynamic>;
      return [
        for (final friend in body)
          AccountFriend.fromJson(friend as Map<String, dynamic>),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Which account [nodeId] is currently a device of, or `null` if it isn't
  /// a device of any account, or the service couldn't be reached.
  ///
  /// `GET <baseUrl>/by-device/<nodeId>` — public and unauthenticated (see
  /// `account_routes.dart`), so this works even before this node's own
  /// device has been linked to an account.
  Future<String?> accountIdForDevice(String nodeId) async {
    final uri = Uri.parse('$baseUrl/by-device/${Uri.encodeComponent(nodeId)}');
    try {
      final response = await _client.get(uri).timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['accountId'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// The current device list of [accountId], or `null` on any failure —
  /// unreachable service, this node not being a mutual friend of that
  /// account (`403`, the gate `account_routes.dart` documents), an unknown
  /// account (`404`), or a malformed response.
  ///
  /// Returning one `null` for all of those is deliberate: every caller
  /// treats "couldn't learn anything" the same way — leave the local cache
  /// exactly as it is. A device list is never *partially* applied. A caller
  /// that also needs to know *why* it learned nothing wants [fetchDevicesOf]
  /// instead.
  Future<List<DeviceLink>?> devicesOf(String accountId) async =>
      (await fetchDevicesOf(accountId)).devices;

  /// [devicesOf]'s underlying outcome, with the one distinction its plain
  /// `null` throws away: whether this service *answered at all*.
  ///
  /// `reachable: false` means the request never got a reply (connection
  /// refused, DNS failure, or [timeout] elapsed) — a condition of the
  /// service as a whole, not of [accountId]. `reachable: true` with
  /// `devices: null` means it answered and the answer was "no" (`403`,
  /// `404`, or something unparseable), which says nothing about the next
  /// account. Only [FriendDeviceRefresher] needs the difference, to decide
  /// whether abandoning the rest of a sweep is warranted — see its
  /// `refreshAll`.
  Future<({List<DeviceLink>? devices, bool reachable})> fetchDevicesOf(
    String accountId,
  ) async {
    final uri = Uri.parse('$baseUrl/${Uri.encodeComponent(accountId)}/devices');
    final http.Response response;
    try {
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'GET', path: uri.path);
      response = await _client.get(uri, headers: headers).timeout(timeout);
    } catch (_) {
      return (devices: null, reachable: false);
    }

    // Everything from here on is this service having answered, so a bad
    // answer is never mistaken for it being down.
    try {
      if (response.statusCode != 200) return (devices: null, reachable: true);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final devices = body['devices'] as List<dynamic>?;
      if (devices == null) return (devices: null, reachable: true);
      return (
        devices: [
          for (final device in devices)
            DeviceLink.fromJson(device as Map<String, dynamic>),
        ],
        reachable: true,
      );
    } catch (_) {
      return (devices: null, reachable: true);
    }
  }

  /// Every *pending* friend request [accountId] is on either side of --
  /// `GET <baseUrl>/<accountId>/friend-requests?status=pending&direction=both`,
  /// signed as this node's own device -- split into the ones it has to answer
  /// and the ones it is waiting on.
  ///
  /// **One request for both lists**, not two: they are the same query with
  /// the same authentication and the same projection, and an app showing both
  /// (which is every app) should not cost two signed round trips per poll.
  /// The split is done here, once, from `fromAccountId`, rather than by each
  /// caller re-deriving the rule.
  ///
  /// `null` on any failure at all (unreachable service, `401`/`403`, an
  /// unparseable body), collapsed exactly like [devicesOf] and [friendsOf]:
  /// every caller does the same thing with all of them, which is to keep
  /// whatever it already had. Two empty lists, by contrast, are a real answer
  /// ("nobody has asked to be your friend, and you are waiting on nobody")
  /// and are distinct from `null` -- [PendingFriendRequestCache] stores the
  /// former and ignores the latter, which is what stops a moment of downtime
  /// from silently emptying the app's lists.
  ///
  /// Against an account service too old to know `direction`, the parameter is
  /// ignored and the answer is the incoming list alone -- so `outgoing` comes
  /// back empty rather than the whole call failing. That degradation is worth
  /// knowing about: an empty outgoing list from an old service is
  /// indistinguishable from a genuinely empty one.
  Future<
    ({
      List<AccountFriendRequest> incoming,
      List<AccountFriendRequest> outgoing,
    })?
  >
  pendingFriendRequestsOf(String accountId) async {
    final uri = Uri.parse(
      '$baseUrl/${Uri.encodeComponent(accountId)}/friend-requests',
    ).replace(queryParameters: {'status': 'pending', 'direction': 'both'});
    try {
      // Signed over the *path only*, matching `RequestSigner`'s canonical
      // string and the account service's own `request.requestedUri.path`:
      // the query string is deliberately outside the signature on both
      // sides, so it must not be included here either.
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'GET', path: uri.path);
      final response = await _client
          .get(uri, headers: headers)
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as List<dynamic>;
      final incoming = <AccountFriendRequest>[];
      final outgoing = <AccountFriendRequest>[];
      for (final entry in body) {
        final request = AccountFriendRequest.fromJson(
          entry as Map<String, dynamic>,
        );
        (request.fromAccountId == accountId ? outgoing : incoming).add(request);
      }
      return (incoming: incoming, outgoing: outgoing);
    } catch (_) {
      return null;
    }
  }

  /// Sends a friend request from [accountId] to whoever currently holds
  /// [toUsername] -- `POST <baseUrl>/<accountId>/friend-requests`
  /// `{toUsername}`, signed as this node's own device.
  ///
  /// Idempotent on the service's side: a second send while one is still
  /// pending in the same direction returns the existing request rather than
  /// creating a second (see `account_routes.dart`), so a user pressing the
  /// button twice is harmless.
  Future<FriendRequestActionResult> sendFriendRequest({
    required String accountId,
    required String toUsername,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/${Uri.encodeComponent(accountId)}/friend-requests',
    );
    final body = jsonEncode({'toUsername': toUsername});
    return _friendRequestAction(() async {
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'POST', path: uri.path, body: body);
      return _client.post(
        uri,
        headers: {...headers, 'content-type': 'application/json'},
        body: body,
      );
    }, successStatus: 201);
  }

  /// Accepts or declines the friend request [requestId] as [accountId] --
  /// `POST <baseUrl>/<accountId>/friend-requests/<requestId>/accept` (or
  /// `/decline`), signed as this node's own device.
  ///
  /// The service only lets a request's *recipient* respond
  /// ([FriendRequestActionOutcome.forbidden] otherwise), and only while it is
  /// still pending ([FriendRequestActionOutcome.conflict] once it isn't).
  Future<FriendRequestActionResult> respondToFriendRequest({
    required String accountId,
    required String requestId,
    required bool accept,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/${Uri.encodeComponent(accountId)}/friend-requests/'
      '${Uri.encodeComponent(requestId)}/${accept ? 'accept' : 'decline'}',
    );
    return _friendRequestAction(() async {
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'POST', path: uri.path);
      return _client.post(uri, headers: headers);
    }, successStatus: 200);
  }

  /// Withdraws the still-pending friend request [requestId] that [accountId]
  /// sent -- `POST <baseUrl>/<accountId>/friend-requests/<requestId>/cancel`,
  /// signed as this node's own device.
  ///
  /// The service only lets a request's **sender** cancel
  /// ([FriendRequestActionOutcome.forbidden] otherwise), and only while it is
  /// still pending ([FriendRequestActionOutcome.conflict] once it isn't --
  /// notably once the other side accepted, at which point the thing to end is
  /// a friendship, not a request).
  Future<FriendRequestActionResult> cancelFriendRequest({
    required String accountId,
    required String requestId,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/${Uri.encodeComponent(accountId)}/friend-requests/'
      '${Uri.encodeComponent(requestId)}/cancel',
    );
    return _friendRequestAction(() async {
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'POST', path: uri.path);
      return _client.post(uri, headers: headers);
    }, successStatus: 200);
  }

  /// Unlinks the device [nodeId] from [accountId] --
  /// `DELETE <baseUrl>/<accountId>/devices/<nodeId>`, signed as this node's
  /// own device, which the service requires to be a device of that same
  /// account.
  ///
  /// **This is the recovery path for a lost or stolen device** (ADR 0048), so
  /// it deliberately does not collapse its failures: see
  /// [UnlinkDeviceOutcome]. Idempotent upstream -- unlinking a nodeId that
  /// was never linked is [UnlinkDeviceOutcome.unlinked], like any `DELETE`.
  Future<UnlinkDeviceOutcome> unlinkDevice({
    required String accountId,
    required String nodeId,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/${Uri.encodeComponent(accountId)}/devices/'
      '${Uri.encodeComponent(nodeId)}',
    );
    final http.Response response;
    try {
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'DELETE', path: uri.path);
      response = await _client.delete(uri, headers: headers).timeout(timeout);
    } catch (_) {
      return UnlinkDeviceOutcome.unreachable;
    }

    // Everything from here on is the service having answered, so a refusal is
    // never reported as it being down.
    if (response.statusCode == 204) return UnlinkDeviceOutcome.unlinked;
    if (response.statusCode >= 400 && response.statusCode < 500) {
      return UnlinkDeviceOutcome.refused;
    }
    return UnlinkDeviceOutcome.failed;
  }

  /// The shared status-to-outcome mapping for the three friend-request
  /// actions above (send, respond, cancel) -- written once because they
  /// answer with the same statuses and the same body, and separate copies
  /// would be free to disagree about what a `409` means.
  Future<FriendRequestActionResult> _friendRequestAction(
    Future<http.Response> Function() send, {
    required int successStatus,
  }) async {
    final http.Response response;
    try {
      response = await send();
    } catch (_) {
      return const FriendRequestActionResult(
        FriendRequestActionOutcome.serviceUnreachable,
        error: 'Could not reach the account service',
      );
    }

    // Everything from here on is the service having answered, so a refusal is
    // never reported as it being down.
    final message = _errorMessageOf(response);
    if (response.statusCode == successStatus) {
      try {
        return FriendRequestActionResult(
          FriendRequestActionOutcome.ok,
          request: AccountFriendRequest.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>,
          ),
        );
      } catch (_) {
        return const FriendRequestActionResult(
          FriendRequestActionOutcome.failed,
          error: 'The account service returned a malformed friend request',
        );
      }
    }
    return FriendRequestActionResult(switch (response.statusCode) {
      400 => FriendRequestActionOutcome.invalid,
      403 => FriendRequestActionOutcome.forbidden,
      404 => FriendRequestActionOutcome.notFound,
      409 => FriendRequestActionOutcome.conflict,
      // A `401` here means this node's own device isn't linked to the account
      // it claims to be -- a broken local session, not something the user can
      // fix by retrying, and not a reason to say the service is down.
      _ => FriendRequestActionOutcome.failed,
    }, error: message);
  }

  /// Ends the friendship between [accountId] (this node's own account) and
  /// [friendAccountId] on the account service --
  /// `DELETE <baseUrl>/<accountId>/friends/<friendAccountId>`, signed as
  /// this node's own device.
  ///
  /// **Never on the critical path of anything.** Local unfriending has
  /// already happened, permanently, by the time this is called; this is the
  /// propagation half, and every one of its failure modes is somebody else's
  /// problem to retry (see `federation/friend_revocation.dart`, which owns
  /// the durable queue and the backoff). It is safe to call repeatedly: the
  /// route is idempotent, so a retry of one that already landed is a
  /// [RevokeFriendshipOutcome.revoked] too.
  Future<RevokeFriendshipOutcome> revokeFriendship({
    required String accountId,
    required String friendAccountId,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/${Uri.encodeComponent(accountId)}/friends/'
      '${Uri.encodeComponent(friendAccountId)}',
    );
    final http.Response response;
    try {
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'DELETE', path: uri.path);
      response = await _client.delete(uri, headers: headers).timeout(timeout);
    } catch (_) {
      return RevokeFriendshipOutcome.failed;
    }

    // Everything from here on is the service having answered, so a refusal is
    // never mistaken for it being down -- and only a refusal is terminal.
    if (response.statusCode == 204) return RevokeFriendshipOutcome.revoked;
    if (response.statusCode == 401 ||
        response.statusCode == 429 ||
        response.statusCode >= 500) {
      return RevokeFriendshipOutcome.failed;
    }
    return response.statusCode >= 400
        ? RevokeFriendshipOutcome.refused
        : RevokeFriendshipOutcome.failed;
  }

  /// Closes the underlying HTTP client, if this instance created it (an
  /// injected one belongs to whoever injected it).
  void close() {
    if (_ownsClient) _client.close();
  }
}
