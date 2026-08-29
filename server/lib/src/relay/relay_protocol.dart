import 'dart:convert';

/// Wire messages exchanged between a [RelayClient][] and the [RelayHub][]
/// over a single persistent WebSocket connection (a "tunnel") — see
/// `docs/adr/0033-self-hosted-relay.md`.
///
/// [RelayClient]: ../relay/relay_client.dart
/// [RelayHub]: ../relay/relay_hub.dart
///
/// The hub never trusts a claimed [RelayHello.nodeId] on its own word: a
/// nodeId is the SHA-256 fingerprint of the node's own Ed25519 public key
/// (see `NodeIdentity`), so it is self-certifying — the hub checks the
/// fingerprint matches, then challenges the connection to sign a fresh
/// nonce with the matching private key before registering the tunnel. This
/// needs no pre-existing trust relationship (the hub isn't, and doesn't
/// need to be, a friend of anyone) — it only proves "this connection really
/// controls nodeId X", never anything about who nodeId X is allowed to talk
/// to. That second question is still answered entirely by the *receiving*
/// Musicat Server's own `RequestVerifier`, exactly as if the forwarded
/// request had arrived directly — the hub is a dumb pipe, on purpose.
abstract class RelayMessage {
  const RelayMessage();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  static RelayMessage decode(String raw) =>
      RelayMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  factory RelayMessage.fromJson(Map<String, dynamic> json) =>
      switch (json['type']) {
        'hello' => RelayHello(
          nodeId: json['nodeId'] as String,
          publicKeyBase64: json['publicKeyBase64'] as String,
        ),
        'challenge' => RelayChallenge(json['nonce'] as String),
        'auth' => RelayAuth(json['signatureBase64'] as String),
        'authResult' => RelayAuthResult(
          success: json['success'] as bool,
          error: json['error'] as String?,
        ),
        'request' => RelayRequestMessage(
          requestId: json['requestId'] as String,
          method: json['method'] as String,
          path: json['path'] as String,
          headers: (json['headers'] as Map<String, dynamic>).map(
            (key, value) => MapEntry(key, value as String),
          ),
          bodyBase64: json['bodyBase64'] as String,
        ),
        'response' => RelayResponseMessage(
          requestId: json['requestId'] as String,
          statusCode: json['statusCode'] as int,
          headers: (json['headers'] as Map<String, dynamic>).map(
            (key, value) => MapEntry(key, value as String),
          ),
          bodyBase64: json['bodyBase64'] as String,
        ),
        'claimUsername' => RelayClaimUsername(json['username'] as String),
        'claimUsernameResult' => RelayClaimUsernameResult(
          success: json['success'] as bool,
          error: json['error'] as String?,
        ),
        _ => throw FormatException(
          'Unknown relay message type: ${json['type']}',
        ),
      };
}

/// First message a [RelayClient] sends: "I claim to be this nodeId, and
/// here is the public key that should hash to it."
class RelayHello extends RelayMessage {
  const RelayHello({required this.nodeId, required this.publicKeyBase64});

  final String nodeId;
  final String publicKeyBase64;

  @override
  Map<String, Object?> toJson() => {
    'type': 'hello',
    'nodeId': nodeId,
    'publicKeyBase64': publicKeyBase64,
  };
}

/// Hub's reply to a [RelayHello] whose fingerprint matched: a fresh random
/// value the client must sign to prove it holds the matching private key.
class RelayChallenge extends RelayMessage {
  const RelayChallenge(this.nonceBase64);

  final String nonceBase64;

  @override
  Map<String, Object?> toJson() => {'type': 'challenge', 'nonce': nonceBase64};
}

/// Client's proof: a signature over the challenge nonce's raw bytes.
class RelayAuth extends RelayMessage {
  const RelayAuth(this.signatureBase64);

  final String signatureBase64;

  @override
  Map<String, Object?> toJson() => {
    'type': 'auth',
    'signatureBase64': signatureBase64,
  };
}

/// Hub's final word on whether the tunnel is now registered.
class RelayAuthResult extends RelayMessage {
  const RelayAuthResult({required this.success, this.error});

  final bool success;
  final String? error;

  @override
  Map<String, Object?> toJson() => {
    'type': 'authResult',
    'success': success,
    'error': error,
  };
}

/// Hub → client: "someone is trying to reach you at this path — handle it
/// exactly like an incoming HTTP request and answer with [RelayResponseMessage]
/// carrying the same [requestId]."
class RelayRequestMessage extends RelayMessage {
  const RelayRequestMessage({
    required this.requestId,
    required this.method,
    required this.path,
    required this.headers,
    required this.bodyBase64,
  });

  final String requestId;
  final String method;
  final String path;
  final Map<String, String> headers;
  final String bodyBase64;

  @override
  Map<String, Object?> toJson() => {
    'type': 'request',
    'requestId': requestId,
    'method': method,
    'path': path,
    'headers': headers,
    'bodyBase64': bodyBase64,
  };
}

/// Client → hub: the answer to a [RelayRequestMessage] with the same
/// [requestId], for the hub to hand back to whoever originally asked.
class RelayResponseMessage extends RelayMessage {
  const RelayResponseMessage({
    required this.requestId,
    required this.statusCode,
    required this.headers,
    required this.bodyBase64,
  });

  final String requestId;
  final int statusCode;
  final Map<String, String> headers;
  final String bodyBase64;

  @override
  Map<String, Object?> toJson() => {
    'type': 'response',
    'requestId': requestId,
    'statusCode': statusCode,
    'headers': headers,
    'bodyBase64': bodyBase64,
  };
}

/// Client → hub: "claim this username as a friendly pointer to my nodeId" --
/// a username is never a new form of authentication or a new account
/// system, just a memorable alias for a nodeId; the nodeId/keypair stays the
/// real trust anchor. Sent over the same already-authenticated channel a
/// [RelayHello]/[RelayAuth] exchange established, not a separate HTTP call:
/// the hub already knows, beyond doubt, which nodeId this connection
/// controls, so reusing that proof is simpler and safer than inventing a
/// second, HTTP-level signature scheme just for this.
class RelayClaimUsername extends RelayMessage {
  const RelayClaimUsername(this.username);

  final String username;

  @override
  Map<String, Object?> toJson() => {
    'type': 'claimUsername',
    'username': username,
  };
}

/// Hub's reply to a [RelayClaimUsername]: whether [RelayClaimUsername.username]
/// now (or already did) resolve to the caller's own nodeId. [error] is a
/// plain, user-presentable string (e.g. "Username already taken", "Invalid
/// username format") and is `null` exactly when [success] is `true`.
class RelayClaimUsernameResult extends RelayMessage {
  const RelayClaimUsernameResult({required this.success, this.error});

  final bool success;
  final String? error;

  @override
  Map<String, Object?> toJson() => {
    'type': 'claimUsernameResult',
    'success': success,
    'error': error,
  };
}
