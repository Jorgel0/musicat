import 'package:http/http.dart' as http;

import 'friend.dart';

Uri _directUri(Friend friend, String path) =>
    Uri.parse('http://${friend.address}$path');

/// The HTTP address to forward a request for [nodeId] through a relay
/// (ADR 0032/0033), given that relay's own base URL as reported at pairing
/// time (`Friend.relayUrl` — its WebSocket connect endpoint, e.g.
/// `ws://relay.example.com:8090/connect`). Always rebuilt from just the
/// scheme/host/port, ignoring whatever path the stored value happens to
/// have, so it doesn't matter whether that value includes `/connect` or
/// not.
Uri relayForwardUri(String relayUrl, String nodeId, String path) {
  final uri = Uri.parse(relayUrl);
  final scheme = uri.scheme == 'wss' ? 'https' : 'http';
  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.port,
    path: '/$nodeId$path',
  );
}

/// Reaches [friend] at their direct [Friend.address] first, falling back
/// to their relay (`Friend.relayUrl`, ADR 0032/0033) only on a genuine
/// network-level failure (timeout, connection refused, DNS failure, ...) —
/// never on an application-level error response (4xx/5xx) from a friend
/// that answered directly, since that's a real answer, not a reachability
/// problem. Rethrows if direct reachability fails and no relay is known.
Future<http.Response> reachFriend(
  http.Client client,
  Friend friend,
  String path, {
  Map<String, String>? headers,
  Duration directTimeout = const Duration(seconds: 5),
}) async {
  try {
    return await client
        .get(_directUri(friend, path), headers: headers)
        .timeout(directTimeout);
  } catch (_) {
    final relayUrl = friend.relayUrl;
    if (relayUrl == null) rethrow;
    return client.get(
      relayForwardUri(relayUrl, friend.nodeId, path),
      headers: headers,
    );
  }
}

/// The streamed equivalent of [reachFriend], for large responses (a shared
/// track's actual file bytes) that shouldn't be buffered in memory.
Future<http.StreamedResponse> reachFriendStreamed(
  http.Client client,
  Friend friend,
  String path, {
  Map<String, String>? headers,
  Duration directTimeout = const Duration(seconds: 5),
}) async {
  try {
    final request = http.Request('GET', _directUri(friend, path))
      ..headers.addAll(headers ?? const {});
    return await client.send(request).timeout(directTimeout);
  } catch (_) {
    final relayUrl = friend.relayUrl;
    if (relayUrl == null) rethrow;
    final request = http.Request(
      'GET',
      relayForwardUri(relayUrl, friend.nodeId, path),
    )..headers.addAll(headers ?? const {});
    return client.send(request);
  }
}
