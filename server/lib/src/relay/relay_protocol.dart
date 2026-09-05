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
        'notify' => RelayNotify(json['event'] as String),
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

/// Hub -> client: "something you care about changed on the account service
/// hosted alongside me -- go and look." **No response is expected, and none
/// is ever sent.**
///
/// This is the *push* half of the "push for convenience, poll for
/// correctness" pair (ADR 0038's pattern, applied to accounts): the
/// guaranteed-eventually-correct half is the node's own periodic poll
/// (`federation/account_update_poller.dart`), and this message only ever
/// makes the node arrive at the same state sooner.
///
/// ## It carries no trusted payload, on purpose
///
/// [event] is an opaque kind ("friendRequests") and there is deliberately
/// nowhere to put an accountId, a username, a key, or a device. A node that
/// receives one does not learn anything from it -- it re-fetches the real
/// data itself, authenticated, from the account service, over its own signed
/// request.
///
/// That is what bounds the damage a **compromised or malicious relay** can
/// do here. The relay is a dumb pipe by design (see [RelayMessage]) and is
/// *not* trusted with content; this message is the one thing it originates
/// rather than forwards, so it is the one place where "the relay said so"
/// could have become "the node believed so". It doesn't: the worst a hostile
/// relay can achieve by spamming these is making a node poll more often than
/// it meant to. It can never inject a friend, a friend request, or a key,
/// because none of those can be expressed in this message at all.
///
/// The same reasoning covers a forged push from anyone else who can write to
/// a node's tunnel: a forgery is indistinguishable from a real one *and has
/// the same effect*, so there is nothing here worth authenticating. All of
/// the security lives in the re-fetch.
///
/// Widening this class to carry data would silently move that trust
/// boundary. Don't.
class RelayNotify extends RelayMessage {
  const RelayNotify(this.event);

  /// The [AccountEvent][]'s name, as an opaque string. Kept a plain
  /// `String` rather than a decoded enum so an unrecognized kind from a
  /// newer hub is a value this client can quietly ignore, not a
  /// [FormatException] -- which, on both sides of this protocol, tears the
  /// whole tunnel down (see `RelayHub._authenticateAndServe` and
  /// `RelayClient._serve`).
  ///
  /// [AccountEvent]: ../accounts/device_notifier.dart
  final String event;

  @override
  Map<String, Object?> toJson() => {'type': 'notify', 'event': event};
}
