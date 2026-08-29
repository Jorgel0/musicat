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
/// A connection that [connect] established successfully and that later
/// drops (relay restarted, network blip, ...) is reconnected automatically
/// in the background, with an exponential backoff capped generously (5
/// minutes by default) to avoid hammering the network on a long outage --
/// deliberately more conservative than a typical desktop-service reconnect
/// loop, since this process can run on a phone on a real mobile data plan.
/// Before each retry, a cheap local check
/// (`NetworkInterface.list()`, no network I/O) skips the attempt entirely
/// if the device currently has no active network interface at all, without
/// counting that tick against the backoff. A *failed initial* [connect]
/// call is never retried automatically -- see its doc comment.
///
/// [RelayHub]: relay_hub.dart
class RelayClient {
  RelayClient({
    required this.identity,
    required this.localHandler,
    this.initialReconnectDelay = const Duration(seconds: 5),
    this.maxReconnectDelay = const Duration(minutes: 5),
  }) : _reconnectDelay = initialReconnectDelay;

  final NodeIdentity identity;
  final Handler localHandler;

  /// How long to wait before the *first* reconnect attempt after a
  /// previously-good connection drops, and what the backoff resets to
  /// after a successful (re)connect. Configurable (rather than a bare
  /// constant) purely so tests don't have to wait out the real
  /// production values below.
  final Duration initialReconnectDelay;

  /// The backoff ceiling -- deliberately generous (5 minutes in
  /// production) because this process can run on a phone on a mobile
  /// data plan: if the relay or the network is down for a long stretch,
  /// steady-state retries should stay infrequent rather than hammering
  /// the radio.
  final Duration maxReconnectDelay;

  static final _algorithm = Ed25519();

  WebSocketChannel? _channel;

  /// The relay this client is supposed to be connected to right now --
  /// non-null exactly when [connect] has succeeded at least once and
  /// [close] hasn't been called since. The automatic reconnect loop below
  /// uses this both as "should I keep retrying after an unexpected drop?"
  /// and as the URL to retry.
  String? _relayUrl;

  /// Bumped by every call to [connect] and every call to [close]. This is
  /// the only thing a scheduled/in-flight reconnect attempt can use to
  /// recognize it has been superseded: [_relayUrl] alone can't tell "no
  /// one wants a connection anymore" (close()) apart from "someone
  /// already established a *newer* one" (a fresh connect()) -- both leave
  /// [_relayUrl] looking perfectly valid to a stale attempt that was
  /// scheduled before either happened. Every scheduled [Timer] and every
  /// in-flight [_attemptConnect] captures the generation that was current
  /// when it started; if that no longer matches [_generation] by the time
  /// it would act, it's stale and no-ops instead -- closing whatever
  /// socket it just opened rather than assigning it to [_channel], and
  /// not rescheduling itself again.
  int _generation = 0;

  /// The current reconnect backoff. Starts at [initialReconnectDelay],
  /// doubles on each failed reconnect attempt (capped at
  /// [maxReconnectDelay]), and resets to [initialReconnectDelay] as soon
  /// as a (re)connect succeeds.
  Duration _reconnectDelay;

  Timer? _reconnectTimer;

  /// The in-flight [claimUsername] call's completer, if any -- there is
  /// realistically only ever one claim happening at a time (driven by the
  /// app's own UI), so a single field is enough; no need for the
  /// [RelayRequestMessage.requestId]-keyed correlation [RelayHub]'s HTTP
  /// forwarding needs to juggle many requests at once. If the tunnel it was
  /// sent on drops before a result arrives, [_serve]'s `finally` fails it
  /// immediately and clears this field, rather than leaving it to expire on
  /// [claimUsername]'s own internal timeout -- see that method's doc
  /// comment.
  Completer<RelayClaimUsernameResult>? _pendingClaim;

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
  ///
  /// A connection reached this way is subject to the automatic reconnect
  /// behavior below if it later drops; a *failed* initial attempt is not
  /// retried in the background -- it returns `false` synchronously, same
  /// as always, leaving that decision entirely to the caller (see
  /// `bin/server.dart`, which uses this return value to decide whether to
  /// advertise this node's relay to friends at startup).
  Future<bool> connect(String relayUrl) async {
    // Cancel whatever this client previously had scheduled for a *past*
    // connection -- without this, calling connect() again after an
    // unexpected drop (e.g. a caller reacting to "network restored")
    // leaves the old scheduled reconnect free to fire later and race with
    // whatever this call establishes. The generation bump below closes
    // the other half of that same race: an old reconnect attempt that was
    // already in flight (timer already fired) rather than merely
    // scheduled -- see [_generation]'s doc comment.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final generation = ++_generation;

    final connected = await _attemptConnect(relayUrl, generation);
    if (connected) {
      _relayUrl = relayUrl;
      _reconnectDelay = initialReconnectDelay;
    }
    return connected;
  }

  Future<bool> _attemptConnect(String relayUrl, int generation) async {
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

      if (generation != _generation) {
        // A newer connect() (or an intentional close()) has already taken
        // over since this specific attempt started -- most likely this
        // was a stale, superseded reconnect (see [_generation]'s doc
        // comment). Tear this connection back down instead of either
        // orphaning it (assigning to _channel would silently leak
        // whatever the newer call already established) or leaving it
        // open unused.
        await channel.sink.close();
        return false;
      }

      _channel = channel;
      unawaited(_serve(channel, messages, generation));
      return true;
    } catch (_) {
      // Relay unreachable, handshake malformed, or any other connection
      // failure -- the caller should treat this the same as "this relay
      // isn't usable right now", not crash.
      return false;
    }
  }

  /// Disconnects and, unlike a connection dropping unexpectedly, does *not*
  /// trigger the automatic reconnect below -- clearing [_relayUrl] and
  /// bumping [_generation] first is what tells [_serve]'s cleanup (and any
  /// already-scheduled or already-in-flight reconnect attempt) that this
  /// was intentional.
  Future<void> close() async {
    _relayUrl = null;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _channel?.sink.close();
    _channel = null;
  }

  /// Claims [username] as a friendly pointer to this node's own nodeId, over
  /// the existing persistent channel established by [connect] -- see
  /// [RelayClaimUsername]'s doc comment for why this piggybacks on the
  /// connection's already-proven identity instead of being a separate,
  /// authenticated-some-other-way HTTP call. Returns a clear failure result
  /// (never throws) if this client isn't currently connected to a relay at
  /// all, or if another claim is already in flight.
  ///
  /// Awaits the *next* [RelayClaimUsernameResult] the relay sends back (see
  /// [_serve]) -- fine as long as only one claim is ever in flight at a
  /// time, which holds here since this is only ever driven by the app's own
  /// UI, never something needing the general per-request correlation
  /// [RelayHub]'s HTTP forwarding uses `requestId`s for. If the tunnel this
  /// claim was sent on drops before a result arrives, [_serve]'s cleanup
  /// fails it promptly with a clear error (rather than this call sitting
  /// idle until its own internal timeout below fires) *and* clears
  /// [_pendingClaim], so a fresh call made right after a successful
  /// automatic reconnect (ADR 0036) is never blocked by a stale, doomed
  /// claim from the dead connection.
  Future<RelayClaimUsernameResult> claimUsername(String username) async {
    final channel = _channel;
    if (channel == null) {
      return const RelayClaimUsernameResult(
        success: false,
        error: 'Not currently connected to a relay',
      );
    }
    if (_pendingClaim != null) {
      return const RelayClaimUsernameResult(
        success: false,
        error: 'Another username claim is already in progress',
      );
    }

    final completer = Completer<RelayClaimUsernameResult>();
    _pendingClaim = completer;
    channel.sink.add(RelayClaimUsername(username).encode());

    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return const RelayClaimUsernameResult(
        success: false,
        error: 'Relay did not respond in time',
      );
    } finally {
      // Only clear this if it's still the completer *this* call created --
      // harmless either way in practice (only one claim is ever really in
      // flight at once), but avoids this call's cleanup ever clobbering a
      // different, newer claim's completer.
      if (identical(_pendingClaim, completer)) {
        _pendingClaim = null;
      }
    }
  }

  Future<void> _serve(
    WebSocketChannel channel,
    StreamIterator<dynamic> messages,
    int generation,
  ) async {
    try {
      while (await messages.moveNext()) {
        final message = RelayMessage.decode(messages.current as String);
        if (message is RelayRequestMessage) {
          unawaited(_handle(channel, message));
        } else if (message is RelayClaimUsernameResult) {
          _pendingClaim?.complete(message);
        }
      }
    } catch (_) {
      // Tunnel dropped -- handled below, same as a clean stream end.
    } finally {
      // Whether *this* connection was still the one _channel pointed to --
      // used below to decide whether a pending claim belongs to this
      // (now-dead) connection or, in the rare case a newer connect()
      // already replaced it before this cleanup ran, to a different,
      // still-healthy one that must be left alone.
      final wasActiveChannel = _channel == channel;
      if (wasActiveChannel) {
        _channel = null;
      }
      // Mirrors RelayHub.disconnect()'s own precedent
      // (_TunnelDisconnectedException, relay_hub.dart): fail a claim still
      // waiting on this tunnel immediately instead of leaving it to expire
      // on claimUsername()'s own 10s internal timeout -- otherwise a claim
      // genuinely in flight when the tunnel drops leaves _pendingClaim set
      // for up to that whole timeout, and claimUsername() unconditionally
      // rejects any *new* claim while it's set, even once the automatic
      // reconnect below has already re-established a perfectly healthy
      // tunnel (often within milliseconds).
      if (wasActiveChannel) {
        final pendingClaim = _pendingClaim;
        if (pendingClaim != null) {
          _pendingClaim = null;
          if (!pendingClaim.isCompleted) {
            pendingClaim.complete(
              const RelayClaimUsernameResult(
                success: false,
                error: 'Connection to the relay was lost, try again',
              ),
            );
          }
        }
      }
      // Only reconnect if this drop wasn't the result of an intentional
      // close() (which clears _relayUrl first, see its doc comment) *and*
      // this connection's generation is still the current one -- an
      // older, already-superseded generation's own drop shouldn't
      // schedule a competing reconnect for a connection nobody is using
      // anymore (a newer connect() already replaced it).
      final relayUrl = _relayUrl;
      if (relayUrl != null && generation == _generation) {
        _scheduleReconnect(relayUrl, generation);
      }
    }
  }

  /// Schedules the next reconnect attempt after [_reconnectDelay], canceling
  /// whatever was previously scheduled first so there's ever only one
  /// pending attempt at a time. [generation] is the generation this
  /// specific reconnect chain belongs to -- see [_generation]'s doc
  /// comment.
  void _scheduleReconnect(String relayUrl, int generation) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () {
      unawaited(_reconnect(relayUrl, generation));
    });
  }

  Future<void> _reconnect(String relayUrl, int generation) async {
    // A newer connect() or an intentional close() may have run since this
    // attempt was scheduled -- honor whichever is current rather than
    // resurrecting or duplicating a connection nobody wants anymore.
    if (generation != _generation) return;

    if (!await _hasNetworkInterface()) {
      // No active network interface at all right now (e.g. airplane mode,
      // mobile data toggled off) -- skip the attempt entirely so this tick
      // spends no data/radio activity, and check again after the same
      // wait without escalating the backoff, since nothing was actually
      // attempted.
      _scheduleReconnect(relayUrl, generation);
      return;
    }

    final reconnected = await _attemptConnect(relayUrl, generation);

    if (generation != _generation) {
      // Superseded while the attempt was in flight (by a newer connect()
      // or a close()) -- _attemptConnect's own generation check already
      // tore the connection back down if it happened to succeed anyway,
      // so there's nothing left to do here, and definitely nothing to
      // reschedule for a generation nobody cares about anymore.
      return;
    }

    if (reconnected) {
      _reconnectDelay = initialReconnectDelay;
    } else {
      _reconnectDelay = _nextReconnectDelay(_reconnectDelay);
      _scheduleReconnect(relayUrl, generation);
    }
  }

  Duration _nextReconnectDelay(Duration current) {
    final doubled = current * 2;
    return doubled > maxReconnectDelay ? maxReconnectDelay : doubled;
  }

  /// A cheap, local-only signal for "does this device have any active
  /// network interface at all right now" -- `NetworkInterface.list()` is
  /// purely an OS query with zero network I/O, so it's safe to call before
  /// every retry tick without itself costing any data/radio activity. This
  /// is *not* a real connectivity check (an interface can be up with no
  /// actual route to the internet, e.g. a Wi-Fi AP with no upstream), just
  /// a reasonable free proxy for the clear-cut "no network at all" case
  /// (airplane mode, mobile data switched off) that's worth skipping an
  /// attempt for entirely.
  Future<bool> _hasNetworkInterface() async {
    try {
      final interfaces = await io.NetworkInterface.list(includeLoopback: false);
      return interfaces.isNotEmpty;
    } catch (_) {
      // If the platform can't answer this at all, don't let that block
      // reconnection forever -- fall back to just attempting.
      return true;
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
