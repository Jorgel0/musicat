import 'dart:convert';

import 'package:http/http.dart' as http;

import '../federation/request_signing.dart';
import '../identity/node_identity.dart';
import 'account.dart';

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
