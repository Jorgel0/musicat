import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'relay_protocol.dart';

Response _json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

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
class RelayHub {
  RelayHub({this.requestTimeout = const Duration(seconds: 20)});

  final Duration requestTimeout;
  final Map<String, _Tunnel> _tunnels = {};
  final Random _random = Random.secure();

  static final _algorithm = Ed25519();

  bool isConnected(String nodeId) => _tunnels.containsKey(nodeId);
  int get connectedCount => _tunnels.length;

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
  Future<void> disconnect(String nodeId) async {
    final tunnel = _tunnels.remove(nodeId);
    await tunnel?.channel.sink.close();
  }

  Router buildRouter() {
    final router = Router();
    router.mount('/connect', webSocketHandler(_onConnection));
    router.all(
      '/<nodeId>/<path|[^]*>',
      (Request request, String nodeId, String path) =>
          _forward(nodeId, path, request),
    );
    return router;
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
      final fingerprint = await Sha256().hash(publicKeyBytes);
      if (_hex(fingerprint.bytes) != hello.nodeId) {
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
    }
  }
}
