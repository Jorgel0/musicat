import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../accounts/device_notifier.dart';
import '../identity/node_identity.dart';
import 'relay_protocol.dart';
import 'username_directory_store.dart';

Response _json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

String _generateId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _Tunnel {
  _Tunnel(this.channel);

  final WebSocketChannel channel;
  final Map<String, Completer<RelayResponseMessage>> pending = {};
}

/// Thrown to fail any request still waiting on a tunnel that
/// [RelayHub.disconnect] just tore down, so [RelayHub._forward] can
/// respond immediately instead of waiting out the full
/// [RelayHub.requestTimeout] for a tunnel it already knows is gone.
class _TunnelDisconnectedException implements Exception {
  const _TunnelDisconnectedException();
}

/// A self-hosted fallback for when direct NAT hole-punching doesn't work
/// (ADR 0021-0024 built it, ADR 0032 found real network pairs where it
/// simply fails). Runs on a host with genuine public reachability — the
/// two friends' own Musicat Servers don't need to be reachable at all,
/// only able to make an *outbound* WebSocket connection, which any NAT
/// permits.
///
/// The hub is deliberately a dumb pipe: it authenticates a connecting node
/// well enough to know "this connection really controls nodeId X" (nodeId
/// is self-certifying, see `relay_protocol.dart`), then forwards whatever
/// HTTP-shaped bytes arrive for X through that tunnel and returns whatever
/// comes back — it never inspects, authorizes, or trusts the *content*
/// being relayed. That's still entirely the receiving Musicat Server's own
/// job (`RequestVerifier`), exactly as if the request had arrived directly.
///
/// It also runs an optional username directory ([usernames]): a node that
/// has already proven it controls nodeId X over its own tunnel (the same
/// [RelayHello]/[RelayAuth] handshake above) can claim a short, memorable
/// username as a friendly pointer to X (a [RelayClaimUsername] message over
/// that same connection), and anyone can resolve one back to a nodeId with
/// a plain `GET /directory/lookup?username=<name>` -- no more sensitive
/// than a nodeId itself, which is already routinely shared via QR
/// codes/links. A username is never a new form of trust or authentication;
/// the nodeId/keypair stays the real trust anchor, exactly as before this
/// existed.
///
/// Finally, it implements [DeviceNotifier] ([notify]) so the account service
/// deployed in this same process (`bin/relay.dart`) can nudge a node over
/// the tunnel it already holds open. That is the *only* thing the hub
/// originates rather than forwards, and it is deliberately contentless --
/// see [RelayNotify] for why a dumb pipe is allowed to say "go look" but
/// never "here is what changed".
class RelayHub implements DeviceNotifier {
  /// [dataDir], if given, is where the `username -> nodeId` directory (see
  /// [usernames]) is persisted across restarts -- a real deployment should
  /// always pass one (see `bin/relay.dart`'s `MUSICAT_RELAY_DATA_DIR`).
  /// Omitting it (the default) falls back to an in-memory-only directory
  /// ([InMemoryUsernameDirectory]) so existing callers that never had a data
  /// directory to begin with (unit tests, an ad hoc `RelayHub()`) keep
  /// working -- just without any claim surviving a restart.
  RelayHub({
    this.requestTimeout = const Duration(seconds: 20),
    Directory? dataDir,
  }) : usernames = dataDir != null
           ? UsernameDirectoryStore(dataDir)
           : InMemoryUsernameDirectory();

  final Duration requestTimeout;
  final UsernameDirectory usernames;
  final Map<String, _Tunnel> _tunnels = {};
  final Random _random = Random.secure();

  static final _algorithm = Ed25519();

  bool isConnected(String nodeId) => _tunnels.containsKey(nodeId);
  int get connectedCount => _tunnels.length;

  /// Pushes a contentless [RelayNotify] to [nodeId]'s tunnel, if it has one
  /// open right now. Returns whether anything was actually sent -- `false`
  /// for a node that isn't currently connected here, which is an ordinary,
  /// expected outcome and not an error: that node's own periodic poll
  /// (`federation/account_update_poller.dart`) is what guarantees it finds
  /// out eventually. Nothing is queued for later delivery, deliberately; a
  /// stored nudge that arrives an hour late is strictly worse than a poll,
  /// and it would give the hub durable per-node state it currently has none
  /// of.
  ///
  /// **Never throws.** The caller is an HTTP handler on the account service
  /// that has already decided its response ([DeviceNotifier.notifyDevice]),
  /// and a failing push must not turn a successful accept into a `500`. A
  /// sink that has just died (the tunnel dropped between the lookup and the
  /// write) is exactly the not-connected case, one moment later.
  bool notify(String nodeId, AccountEvent event) {
    final tunnel = _tunnels[nodeId];
    if (tunnel == null) return false;
    try {
      tunnel.channel.sink.add(RelayNotify(event.name).encode());
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void notifyDevice(String nodeId, AccountEvent event) => notify(nodeId, event);

  /// Forcibly closes [nodeId]'s tunnel from this side, if one is currently
  /// open -- a no-op otherwise. Useful operationally (e.g. kicking a
  /// misbehaving node) and, in `relay_client_test.dart`, to simulate a
  /// relay-initiated drop (a network blip, or the hub restarting) without
  /// touching the listening socket: once a connection has been upgraded to
  /// a WebSocket it's hijacked away from the underlying `HttpServer`
  /// entirely (a real `dart:io`/`shelf` behavior, not a contrivance of
  /// this codebase), so even `HttpServer.close(force: true)` leaves
  /// already-open tunnels running -- this closes the specific tunnel's
  /// channel directly instead.
  ///
  /// Also immediately fails any request still in flight on this tunnel
  /// (i.e. still waiting in [_Tunnel.pending]) rather than leaving it to
  /// wait out the full [requestTimeout] for a tunnel the hub already knows
  /// is gone -- see [_forward].
  Future<void> disconnect(String nodeId) async {
    final tunnel = _tunnels.remove(nodeId);
    if (tunnel != null) {
      for (final completer in tunnel.pending.values) {
        completer.completeError(const _TunnelDisconnectedException());
      }
      tunnel.pending.clear();
    }
    await tunnel?.channel.sink.close();
  }

  Router buildRouter() {
    final router = Router();
    router.mount('/connect', webSocketHandler(_onConnection));
    // Registered before the catch-all forwarding route below: shelf_router
    // tries routes in registration order and uses the first match (see its
    // own doc comment), and '/<nodeId>/<path|[^]*>' would otherwise happily
    // match '/directory/lookup' too (nodeId='directory', path='lookup') --
    // no real nodeId is ever literally "directory" (it's a 64-char hex
    // fingerprint), but registration order is what actually guarantees this
    // route wins, not that coincidence.
    router.get('/directory/lookup', _lookupUsername);
    router.all(
      '/<nodeId>/<path|[^]*>',
      (Request request, String nodeId, String path) =>
          _forward(nodeId, path, request),
    );
    return router;
  }

  /// Plain, unauthenticated HTTP GET: read-only and no more sensitive than a
  /// nodeId itself (already routinely shared via QR codes/links), so it
  /// needs no auth at all -- see [RelayClaimUsername]'s doc comment for why
  /// *claiming* one is different.
  Future<Response> _lookupUsername(Request request) async {
    final username = request.requestedUri.queryParameters['username'];
    if (username == null || username.isEmpty) {
      return _json({
        'error': '"username" query parameter is required',
      }, status: 400);
    }

    final nodeId = await usernames.lookup(username);
    if (nodeId == null) {
      return _json({'error': 'Username not found'}, status: 404);
    }
    return _json({'nodeId': nodeId});
  }

  void _onConnection(WebSocketChannel channel, String? protocol) {
    unawaited(_authenticateAndServe(channel));
  }

  Future<void> _authenticateAndServe(WebSocketChannel channel) async {
    // A single StreamIterator for the connection's whole lifetime -- the
    // underlying stream may be single-subscription, so listening to it
    // more than once (e.g. via separate `.first` calls for hello then
    // auth) would throw on the second attempt.
    final messages = StreamIterator<dynamic>(channel.stream);
    String? nodeId;
    try {
      if (!await messages.moveNext().timeout(const Duration(seconds: 10))) {
        return;
      }
      final hello = RelayMessage.decode(messages.current as String);
      if (hello is! RelayHello) {
        await channel.sink.close();
        return;
      }

      final publicKeyBytes = base64Decode(hello.publicKeyBase64);
      if (await nodeIdForPublicKey(publicKeyBytes) != hello.nodeId) {
        channel.sink.add(
          const RelayAuthResult(
            success: false,
            error: 'nodeId does not match publicKeyBase64',
          ).encode(),
        );
        await channel.sink.close();
        return;
      }

      final nonceBytes = List<int>.generate(24, (_) => _random.nextInt(256));
      channel.sink.add(RelayChallenge(base64Encode(nonceBytes)).encode());

      if (!await messages.moveNext().timeout(const Duration(seconds: 10))) {
        return;
      }
      final auth = RelayMessage.decode(messages.current as String);
      if (auth is! RelayAuth) {
        await channel.sink.close();
        return;
      }

      final publicKey = SimplePublicKey(
        publicKeyBytes,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        base64Decode(auth.signatureBase64),
        publicKey: publicKey,
      );
      final isValid = await _algorithm.verify(nonceBytes, signature: signature);
      if (!isValid) {
        channel.sink.add(
          const RelayAuthResult(
            success: false,
            error: 'invalid signature',
          ).encode(),
        );
        await channel.sink.close();
        return;
      }

      nodeId = hello.nodeId;
      _tunnels[nodeId] = _Tunnel(channel);
      channel.sink.add(const RelayAuthResult(success: true).encode());

      while (await messages.moveNext()) {
        final message = RelayMessage.decode(messages.current as String);
        if (message is RelayResponseMessage) {
          _tunnels[nodeId]?.pending
              .remove(message.requestId)
              ?.complete(message);
        } else if (message is RelayClaimUsername) {
          final result = await usernames.claim(message.username, nodeId);
          channel.sink.add(
            RelayClaimUsernameResult(
              success: result.success,
              error: result.error,
            ).encode(),
          );
        }
      }
    } catch (_) {
      // Connection dropped, or malformed traffic -- fall through to cleanup.
    } finally {
      if (nodeId != null && _tunnels[nodeId]?.channel == channel) {
        _tunnels.remove(nodeId);
      }
    }
  }

  Future<Response> _forward(String nodeId, String path, Request request) async {
    final tunnel = _tunnels[nodeId];
    if (tunnel == null) {
      return _json({
        'error': 'Target node is not connected to this relay',
      }, status: 502);
    }

    final requestId = _generateId();
    final bodyBytes = await request.read().expand((chunk) => chunk).toList();
    final completer = Completer<RelayResponseMessage>();
    tunnel.pending[requestId] = completer;

    final query = request.requestedUri.hasQuery
        ? '?${request.requestedUri.query}'
        : '';
    tunnel.channel.sink.add(
      RelayRequestMessage(
        requestId: requestId,
        method: request.method,
        path: '/$path$query',
        headers: request.headers,
        bodyBase64: base64Encode(bodyBytes),
      ).encode(),
    );

    try {
      final response = await completer.future.timeout(requestTimeout);
      return Response(
        response.statusCode,
        body: base64Decode(response.bodyBase64),
        headers: response.headers,
      );
    } on TimeoutException {
      tunnel.pending.remove(requestId);
      return _json({
        'error': 'Target node did not respond in time',
      }, status: 504);
    } on _TunnelDisconnectedException {
      // disconnect() already removed this tunnel (and completed/cleared
      // this request's own completer) -- nothing left to clean up here,
      // just respond promptly instead of waiting out requestTimeout for a
      // tunnel already known to be gone. 502 (not 504) since this isn't a
      // timeout -- the hub has definitive, immediate knowledge the target
      // is unreachable, same status as "never was connected" above.
      return _json({
        'error': 'Target node disconnected before responding',
      }, status: 502);
    }
  }
}
