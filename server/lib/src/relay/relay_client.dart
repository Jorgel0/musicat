import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../identity/node_identity.dart';
import 'relay_protocol.dart';

/// Connects this node OUT to a [RelayHub][] and services whatever requests
/// arrive through that tunnel by handing them to [localHandler] -- the
/// exact same handler the server already uses for direct HTTP
/// (`bin/server.dart`'s own router). A request that arrives through the
/// relay is therefore handled completely identically to one that arrived
/// directly: every route's own authorization checks (`RequestVerifier`,
/// object-level checks, ...) apply unchanged, since the relay hub never
/// sees or needs to see the request's actual content (ADR 0032/0033).
///
/// Only an *outbound* connection is ever made here, which every NAT
/// permits -- this is the fallback for when direct hole-punching (ADR
/// 0021-0024) didn't work for a given pair of networks.
///
/// [RelayHub]: relay_hub.dart
class RelayClient {
  RelayClient({required this.identity, required this.localHandler});

  final NodeIdentity identity;
  final Handler localHandler;

  static final _algorithm = Ed25519();

  WebSocketChannel? _channel;

  bool get isConnected => _channel != null;

  /// Connects to [relayUrl] (its WebSocket endpoint, e.g.
  /// `ws://relay.example.com/connect`), authenticates, and starts
  /// servicing incoming requests in the background. Returns whether
  /// authentication succeeded -- callers should treat `false` as "this
  /// relay isn't usable right now", not a fatal error.
  ///
  /// Deliberately connects via `WebSocket.connect()` first and only wraps
  /// the result afterwards, rather than the more concise
  /// `IOWebSocketChannel.connect(uri)`: that convenience constructor wraps
  /// a not-yet-connected socket in a lazy `Future`, and a connection
  /// failure (e.g. nothing listening at [relayUrl]) surfaces *twice* --
  /// once as a catchable stream error, and once as a genuinely separate
  /// unhandled async error from the channel's internal sink-side
  /// subscription to that same future, which no try/catch around this
  /// method can reach. Connecting first sidesteps that path entirely.
  Future<bool> connect(String relayUrl) async {
    try {
      final socket = await io.WebSocket.connect(
        relayUrl,
      ).timeout(const Duration(seconds: 10));
      final channel = IOWebSocketChannel(socket);
      final messages = StreamIterator<dynamic>(channel.stream);

      final publicKey = await identity.publicKeyBase64();
      channel.sink.add(
        RelayHello(
          nodeId: identity.nodeId,
          publicKeyBase64: publicKey,
        ).encode(),
      );

      if (!await messages.moveNext().timeout(const Duration(seconds: 10))) {
        return false;
      }
      final challenge = RelayMessage.decode(messages.current as String);
      if (challenge is! RelayChallenge) return false;

      final signature = await _algorithm.sign(
        base64Decode(challenge.nonceBase64),
        keyPair: identity.keyPair,
      );
      channel.sink.add(RelayAuth(base64Encode(signature.bytes)).encode());

      if (!await messages.moveNext().timeout(const Duration(seconds: 10))) {
        return false;
      }
      final result = RelayMessage.decode(messages.current as String);
      if (result is! RelayAuthResult || !result.success) return false;

      _channel = channel;
      unawaited(_serve(channel, messages));
      return true;
    } catch (_) {
      // Relay unreachable, handshake malformed, or any other connection
      // failure -- the caller should treat this the same as "this relay
      // isn't usable right now", not crash.
      return false;
    }
  }

  Future<void> close() async {
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> _serve(
    WebSocketChannel channel,
    StreamIterator<dynamic> messages,
  ) async {
    try {
      while (await messages.moveNext()) {
        final message = RelayMessage.decode(messages.current as String);
        if (message is RelayRequestMessage) {
          unawaited(_handle(channel, message));
        }
      }
    } catch (_) {
      // Tunnel dropped -- nothing more to serve until reconnected.
    } finally {
      if (_channel == channel) {
        _channel = null;
      }
    }
  }

  Future<void> _handle(
    WebSocketChannel channel,
    RelayRequestMessage message,
  ) async {
    final request = Request(
      message.method,
      Uri.parse('http://relay-tunnel${message.path}'),
      headers: message.headers,
      body: base64Decode(message.bodyBase64),
    );

    final Response response;
    try {
      response = await localHandler(request);
    } catch (e) {
      channel.sink.add(
        RelayResponseMessage(
          requestId: message.requestId,
          statusCode: 500,
          headers: const {'content-type': 'application/json'},
          bodyBase64: base64Encode(utf8.encode('{"error":"$e"}')),
        ).encode(),
      );
      return;
    }

    final bodyBytes = await response.read().expand((chunk) => chunk).toList();
    channel.sink.add(
      RelayResponseMessage(
        requestId: message.requestId,
        statusCode: response.statusCode,
        headers: response.headers,
        bodyBase64: base64Encode(bodyBytes),
      ).encode(),
    );
  }
}
