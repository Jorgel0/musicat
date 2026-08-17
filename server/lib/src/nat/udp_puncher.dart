import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../federation/friend_store.dart';
import '../federation/request_signing.dart';
import '../identity/node_identity.dart';
import 'stun_client.dart';

/// UDP hole-punching for Fase 4 federation (ADR 0023).
///
/// Reuses [RequestSigner]/[RequestVerifier]'s exact signing scheme (ADR
/// 0019) for punch packets — a fixed pseudo method/path stands in for the
/// method/path an HTTP request would have, so accepting a signed punch
/// packet on this socket is exactly as trustworthy as accepting a signed
/// HTTP request from the same friend, not a separate, weaker trust check.
class UdpPuncher {
  UdpPuncher({required this.identity, required this.friendStore});

  final NodeIdentity identity;
  final FriendStore friendStore;

  static const _punchMethod = 'UDP-PUNCH';
  static const _punchPath = '/nat/punch';

  RawDatagramSocket? _socket;
  StunAddress? _cachedCandidate;

  /// The local port this puncher is bound to — the same port must be used
  /// for [refreshCandidate] and for actual [punch] attempts, since a NAT
  /// mapping is tied to the specific local socket that created it.
  int? get localPort => _socket?.port;

  /// This node's own external UDP mapping as of the last [refreshCandidate]
  /// call — `null` until that's been called at least once. A synchronous,
  /// no-network-call getter deliberately: request handlers that want to
  /// report this node's candidate (e.g. the `/friends` route) shouldn't
  /// each trigger their own live STUN round-trip.
  StunAddress? get cachedCandidate => _cachedCandidate;

  Future<int> bind({int port = 0}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _socket = socket;
    return socket.port;
  }

  Future<void> close() async {
    _socket?.close();
    _socket = null;
  }

  /// Re-discovers this node's own external UDP mapping via STUN, using the
  /// currently bound local port, and updates [cachedCandidate].
  Future<StunAddress?> refreshCandidate({
    String stunServer = 'stun.l.google.com',
    int stunPort = 19302,
  }) async {
    final socket = _socket;
    if (socket == null) throw StateError('bind() must be called first');
    final result = await StunClient().discover(
      localPort: socket.port,
      server: stunServer,
      stunPort: stunPort,
    );
    _cachedCandidate = result;
    return result;
  }

  /// Sends repeated signed punch packets toward [host]:[port] for
  /// [duration], while listening for a validly-signed incoming packet from
  /// any known friend. Returns the `nodeId` of whichever friend's signed
  /// packet is received first, or `null` if none arrives in time.
  ///
  /// Sending *and* listening throughout the whole window (rather than a
  /// single packet) is deliberate: hole-punching needs both sides' outbound
  /// packets to cross paths roughly together, and there's no way to know
  /// the other side's exact timing, so a repeated burst over a few seconds
  /// stands a much better chance than one perfectly-timed packet.
  Future<String?> punch({
    required String host,
    required int port,
    Duration duration = const Duration(seconds: 5),
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    final socket = _socket;
    if (socket == null) throw StateError('bind() must be called first');

    final targetAddress = await _resolve(host);
    if (targetAddress == null) return null;

    final verifier = RequestVerifier(friendStore);
    final completer = Completer<String?>();
    final subscription = socket.listen((event) async {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final nodeId = await _verifyIncoming(verifier, datagram.data);
      if (nodeId != null && !completer.isCompleted) {
        completer.complete(nodeId);
      }
    });

    final payload = utf8.encode(
      jsonEncode(
        await RequestSigner(
          identity,
        ).sign(method: _punchMethod, path: _punchPath),
      ),
    );

    final timer = Timer.periodic(interval, (_) {
      socket.send(payload, targetAddress, port);
    });
    // Fire one immediately rather than waiting for the first tick.
    socket.send(payload, targetAddress, port);

    final result = await completer.future.timeout(
      duration,
      onTimeout: () => null,
    );
    timer.cancel();
    await subscription.cancel();
    return result;
  }

  Future<String?> _verifyIncoming(
    RequestVerifier verifier,
    List<int> data,
  ) async {
    try {
      final headers = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final result = await verifier.verify(
        method: _punchMethod,
        path: _punchPath,
        body: '',
        nodeId: headers['X-Node-Id'] as String?,
        timestamp: headers['X-Timestamp'] as String?,
        signatureBase64: headers['X-Signature'] as String?,
      );
      return result == RequestVerificationResult.valid
          ? headers['X-Node-Id'] as String?
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<InternetAddress?> _resolve(String host) async {
    final addresses = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    );
    return addresses.isEmpty ? null : addresses.first;
  }
}
