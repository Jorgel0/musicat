import 'package:http/http.dart' as http;

import 'friend.dart';

/// Thrown when a friend has no known way to be reached at all — no device
/// with an address, and none with a relay. Distinct from a device that was
/// tried and failed (that error is rethrown as-is), and only really
/// possible for an account-based friend whose devices were all learned from
/// the account service, which records keys but no addresses.
class FriendUnreachableException implements Exception {
  const FriendUnreachableException(this.accountId);

  final String accountId;

  @override
  String toString() =>
      'No known address or relay for friend account $accountId';
}

/// The relay's own plain-HTTP origin (scheme/host/port only, no path), given
/// its WebSocket connect endpoint (e.g. `ws://relay.example.com:8090/connect`
/// -> `http://relay.example.com:8090`, `wss://...` -> `https://...`).
/// Ignores whatever path the given URL happens to have -- callers attach
/// their own via [Uri.replace] -- so it doesn't matter whether that value
/// includes `/connect` or not.
///
/// Shared by [relayForwardUri] below (which forwards a request to a specific
/// node through the relay) and by `federation_routes.dart`'s `GET
/// /api/v1/federation/directory/lookup` (which calls the relay's *own*
/// `/directory/lookup`, not a specific node) -- both need this exact
/// ws(s)://-to-http(s):// mapping, and duplicating it in two places is
/// exactly the kind of thing that drifts.
Uri relayHttpOrigin(String relayUrl) {
  final uri = Uri.parse(relayUrl);
  final scheme = uri.scheme == 'wss' ? 'https' : 'http';
  return Uri(scheme: scheme, host: uri.host, port: uri.port);
}

/// The HTTP address to forward a request for [nodeId] through a relay
/// (ADR 0032/0033), given that relay's own base URL as reported at pairing
/// time (`FriendDevice.relayUrl` — its WebSocket connect endpoint, e.g.
/// `ws://relay.example.com:8090/connect`). Always rebuilt from just the
/// scheme/host/port (see [relayHttpOrigin]), ignoring whatever path the
/// stored value happens to have, so it doesn't matter whether that value
/// includes `/connect` or not.
Uri relayForwardUri(String relayUrl, String nodeId, String path) =>
    relayHttpOrigin(relayUrl).replace(path: '/$nodeId$path');

/// One way to reach one of a friend's devices.
class _Candidate {
  const _Candidate(this.uri, {required this.viaRelay});

  final Uri uri;
  final bool viaRelay;
}

/// Every way this node currently knows of to reach [friend], in the order
/// to try them: **every** device's direct address first (in
/// [Friend.devicesByPreference] order, most-recently-linked first), and
/// only then every device's relay, in that same order.
///
/// The direct-then-relay preference is the same one that existed before
/// accounts did, but it is applied across the whole friend rather than per
/// device, and that is deliberate. Interleaving them per device
/// (`[phone-direct, phone-relay, desktop-direct, ...]`) puts one device's
/// *relay* ahead of another device's *direct* address, so a friend whose
/// old phone still has a stale relay cached could only be reached on the
/// same LAN after that dead relay had been tried and given up on — turning
/// a millisecond-scale local download into a minutes-long one. A device
/// that answers on the local network must never sit behind another
/// device's relay. Relays are the fallback for *this friend*, not for one
/// of their devices.
///
/// A device with no known address contributes only its relay candidate (if
/// it has one), and one with neither contributes nothing.
List<_Candidate> _candidates(Friend friend, String path) {
  final devices = friend.devicesByPreference;
  final direct = <_Candidate>[];
  final viaRelay = <_Candidate>[];
  for (final device in devices) {
    final address = device.address;
    if (address != null && address.isNotEmpty) {
      direct.add(
        _Candidate(Uri.parse('http://$address$path'), viaRelay: false),
      );
    }
    final relayUrl = device.relayUrl;
    if (relayUrl != null && relayUrl.isNotEmpty) {
      viaRelay.add(
        _Candidate(
          relayForwardUri(relayUrl, device.nodeId, path),
          viaRelay: true,
        ),
      );
    }
  }
  return [...direct, ...viaRelay];
}

/// Tries [attempt] against each of [friend]'s candidates in turn, moving on
/// only on a genuine network-level failure (timeout, connection refused,
/// DNS failure, ...) — never on an application-level error response
/// (4xx/5xx), since that's a real answer from a device that answered, not a
/// reachability problem. Rethrows the last failure if every candidate
/// fails, and throws [FriendUnreachableException] if there were none.
///
/// **Every** attempt is bounded, so the chain as a whole always terminates:
/// a candidate that neither answers nor refuses (a blackholed address, a
/// relay host that has since gone away) would otherwise stall on the OS's
/// own TCP connect timeout, which is tens of seconds and multiplies by the
/// number of such candidates. [directTimeout] bounds a direct attempt and
/// [relayTimeout] a relayed one; they are separate values because they
/// bound genuinely different things — a direct attempt is usually a hop on
/// the local network, while a relayed one crosses the internet twice (here
/// to the relay, relay to the friend) and legitimately takes longer, so
/// reusing the direct budget for it would abandon working relays. What
/// matters is that both are finite, not that either is fast.
Future<T> _reachAny<T>(
  Friend friend,
  String path,
  Duration directTimeout,
  Duration relayTimeout,
  Future<T> Function(Uri uri) attempt,
) async {
  final candidates = _candidates(friend, path);
  if (candidates.isEmpty) {
    throw FriendUnreachableException(friend.accountId);
  }

  Object lastError = FriendUnreachableException(friend.accountId);
  StackTrace lastStackTrace = StackTrace.current;
  for (final candidate in candidates) {
    try {
      return await attempt(
        candidate.uri,
      ).timeout(candidate.viaRelay ? relayTimeout : directTimeout);
    } catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
    }
  }
  Error.throwWithStackTrace(lastError, lastStackTrace);
}

/// Reaches [friend] at each of their known devices' direct addresses,
/// falling back to those devices' relays (ADR 0032/0033) only once every
/// direct address has failed, and only on genuine network-level failures —
/// see [_reachAny] and [_candidates] for the exact rules.
///
/// [relayTimeout] is deliberately more generous than [directTimeout]: see
/// [_reachAny].
Future<http.Response> reachFriend(
  http.Client client,
  Friend friend,
  String path, {
  Map<String, String>? headers,
  Duration directTimeout = const Duration(seconds: 5),
  Duration relayTimeout = const Duration(seconds: 15),
}) => _reachAny(
  friend,
  path,
  directTimeout,
  relayTimeout,
  (uri) => client.get(uri, headers: headers),
);

/// The streamed equivalent of [reachFriend], for large responses (a shared
/// track's actual file bytes) that shouldn't be buffered in memory.
///
/// Both timeouts bound only *getting a response back*, never how long the
/// body then takes to stream: the returned [http.StreamedResponse] is
/// handed to the caller untouched once its headers have arrived, so a slow
/// but progressing multi-megabyte download is never cut off.
Future<http.StreamedResponse> reachFriendStreamed(
  http.Client client,
  Friend friend,
  String path, {
  Map<String, String>? headers,
  Duration directTimeout = const Duration(seconds: 5),
  Duration relayTimeout = const Duration(seconds: 15),
}) => _reachAny(friend, path, directTimeout, relayTimeout, (uri) {
  final request = http.Request('GET', uri)..headers.addAll(headers ?? const {});
  return client.send(request);
});
