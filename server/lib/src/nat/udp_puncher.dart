import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../federation/friend_store.dart';
import '../federation/request_signing.dart';
import '../identity/node_identity.dart';
import 'stun_client.dart';

/// UDP hole-punching and keepalive for Fase 4 federation (ADR 0023/0024).
///
/// Reuses [RequestSigner]/[RequestVerifier]'s exact signing scheme (ADR
/// 0019) for every packet sent on this socket — a fixed pseudo method/path
/// stands in for the method/path an HTTP request would have. The same
/// signed payload shape is used for the initial punch burst and for
/// ongoing keepalives: from a trust standpoint both are just "prove you're
/// nodeId X", so there's no need for the wire protocol to distinguish them.
class UdpPuncher {
  UdpPuncher({required this.identity, required this.friendStore});

  final NodeIdentity identity;
  final FriendStore friendStore;

  static const _method = 'UDP-PUNCH';
  static const _path = '/nat/punch';

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _listenerSubscription;
  final StreamController<String> _validPacketController =
      StreamController<String>.broadcast();
  final Map<String, DateTime> _lastSeen = {};
  final Map<String, Timer> _keepaliveTimers = {};

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
    // Deliberately a bare, local-only verifier (no UnknownDeviceResolver):
    // an unsigned/unknown UDP packet must never be able to make this node
    // call the account service -- these arrive unsolicited from anywhere.
    final verifier = RequestVerifier(friendStore);
    _listenerSubscription = socket.listen((event) async {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final nodeId = await _verifyIncoming(verifier, datagram.data);
      if (nodeId != null) {
        _lastSeen[nodeId] = DateTime.now();
        _validPacketController.add(nodeId);
      }
    });
    return socket.port;
  }

  Future<void> close() async {
    for (final timer in _keepaliveTimers.values) {
      timer.cancel();
    }
    _keepaliveTimers.clear();
    await _listenerSubscription?.cancel();
    _listenerSubscription = null;
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

  /// When a validly-signed packet from [nodeId] was last received — `null`
  /// if none ever has been.
  DateTime? lastSeen(String nodeId) => _lastSeen[nodeId];

  /// Whether a signed packet from [nodeId] arrived within [within] of now —
  /// the practical "is this friend's hole still open" check, since a NAT
  /// mapping that isn't actively refreshed can silently expire.
  bool isConnected(
    String nodeId, {
    Duration within = const Duration(seconds: 45),
  }) {
    final seen = _lastSeen[nodeId];
    return seen != null && DateTime.now().difference(seen) <= within;
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

    // .then<String?> actually rewraps the Future (not just a static-type
    // widening) so .timeout()'s onTimeout can return null below.
    final firstValid = _validPacketController.stream.first.then<String?>(
      (value) => value,
    );
    final payload = await _signedPayload();

    final timer = Timer.periodic(interval, (_) {
      socket.send(payload, targetAddress, port);
    });
    // Fire one immediately rather than waiting for the first tick.
    socket.send(payload, targetAddress, port);

    final result = await firstValid.timeout(duration, onTimeout: () => null);
    timer.cancel();
    return result;
  }

  /// [punch]es toward [host]:[port], then starts a [startKeepalive] loop
  /// for [nodeId] regardless of whether that initial punch heard anything
  /// back. Returns whether it did.
  ///
  /// Keepalives are started unconditionally — confirmed here with two real
  /// server processes: each side's outbound packets are what keep *its
  /// own* NAT mapping open for the peer to reach it, independent of
  /// whether it has itself confirmed the reverse direction yet. Gating
  /// keepalives on `punch()`'s own success caused a real, observed bug —
  /// one side's packets were reaching the other fine, but because that
  /// side's own `punch()` call happened to time out waiting to hear back
  /// within its 5-second window, it gave up and stopped sending
  /// altogether, even though it was already working one-way and likely
  /// would have gone both ways shortly after.
  Future<bool> punchAndMaintain({
    required String nodeId,
    required String host,
    required int port,
    Duration punchDuration = const Duration(seconds: 5),
    Duration keepaliveInterval = const Duration(seconds: 20),
  }) async {
    final result = await punch(host: host, port: port, duration: punchDuration);
    startKeepalive(
      nodeId: nodeId,
      host: host,
      port: port,
      interval: keepaliveInterval,
    );
    return result != null;
  }

  /// Starts sending a signed packet toward [host]:[port] every [interval],
  /// so the NAT mapping [punch] opened for [nodeId] doesn't expire from
  /// inactivity. Calling this again for the same [nodeId] replaces the
  /// previous loop (e.g. after a fresh pairing changed the candidate).
  void startKeepalive({
    required String nodeId,
    required String host,
    required int port,
    Duration interval = const Duration(seconds: 20),
  }) {
    final socket = _socket;
    if (socket == null) throw StateError('bind() must be called first');
    stopKeepalive(nodeId);

    unawaited(() async {
      final targetAddress = await _resolve(host);
      final currentSocket = _socket;
      // bind()/close() or another startKeepalive(nodeId) call may have
      // happened while resolving the address above — bail rather than
      // arm a timer for a socket that's gone or has been superseded.
      if (targetAddress == null ||
          currentSocket == null ||
          _keepaliveTimers.containsKey(nodeId)) {
        return;
      }
      final payload = await _signedPayload();
      _keepaliveTimers[nodeId] = Timer.periodic(interval, (_) {
        currentSocket.send(payload, targetAddress, port);
      });
    }());
  }

  void stopKeepalive(String nodeId) {
    _keepaliveTimers.remove(nodeId)?.cancel();
  }

  bool isMaintaining(String nodeId) => _keepaliveTimers.containsKey(nodeId);

  Future<List<int>> _signedPayload() async {
    final headers = await RequestSigner(
      identity,
    ).sign(method: _method, path: _path);
    return utf8.encode(jsonEncode(headers));
  }

  Future<String?> _verifyIncoming(
    RequestVerifier verifier,
    List<int> data,
  ) async {
    try {
      final headers = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final verification = await verifier.verify(
        method: _method,
        path: _path,
        body: '',
        nodeId: headers['X-Node-Id'] as String?,
        timestamp: headers['X-Timestamp'] as String?,
        signatureBase64: headers['X-Signature'] as String?,
      );
      // Keyed by the *device* that sent the packet, not its friend
      // account: a NAT mapping is per socket, so liveness is per device.
      return verification.deviceNodeId;
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
