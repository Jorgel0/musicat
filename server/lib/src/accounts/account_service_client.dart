import 'dart:convert';

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

  /// `400` from the username format rule shared with the username directory
  /// (`usernamePattern`). Only reachable on signup.
  invalidUsername,

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

  const AccountLoginResult.failure(AccountLoginOutcome outcome, {String? error})
    : this._(outcome, error: error);

  final AccountLoginOutcome outcome;
  final String? accountId;

  /// The username the account service echoed back -- the canonical spelling
  /// of it, rather than whatever the caller typed.
  final String? username;

  /// The account service's own `{"error": ...}` message, when it sent one.
  /// Never contains anything the caller submitted (the account service never
  /// echoes a password back), so it is safe to forward to the app.
  final String? error;

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
  }) : baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// The account service's own base URL, e.g.
  /// `http://relay.example.com:8090/accounts` — the relay's HTTP origin
  /// plus the prefix `bin/relay.dart` mounts the account router at. Any
  /// trailing slash is normalized away.
  final String baseUrl;

  final NodeIdentity identity;

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
    switch (complete.statusCode) {
      case 429:
        return AccountLoginResult.failure(
          AccountLoginOutcome.rateLimited,
          error: message,
        );
      case 401:
        return AccountLoginResult.failure(
          AccountLoginOutcome.wrongPassword,
          error: message,
        );
      case 400:
        return AccountLoginResult.failure(
          AccountLoginOutcome.invalidUsername,
          error: message,
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
        );
    }
  }

  /// The account service's own `{"error": ...}` message from [response], or
  /// `null` if it didn't send one in that shape. Never includes the raw body
  /// as a fallback: an unexpected body could be anything at all, and this
  /// value is forwarded to the app.
  String? _errorMessageOf(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) return body['error'] as String?;
    } catch (_) {
      // Deliberately silent: a non-JSON body just means there's no message.
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

  /// Closes the underlying HTTP client, if this instance created it (an
  /// injected one belongs to whoever injected it).
  void close() {
    if (_ownsClient) _client.close();
  }
}
