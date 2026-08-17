import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _magicCookie = 0x2112A442;

/// An address as a STUN server observed it — this node's real, public
/// `ip:port` for a given local socket, as seen from outside its own NAT.
class StunAddress {
  const StunAddress(this.address, this.port);

  final String address;
  final int port;

  @override
  String toString() => '$address:$port';

  @override
  bool operator ==(Object other) =>
      other is StunAddress && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);
}

/// Whether independent STUN servers agree on this node's external mapping
/// for the same local port — see [StunClient.detectMappingBehavior].
enum NatMappingBehavior { consistent, variesByDestination, unknown }

/// Builds a STUN (RFC 5389) Binding Request with a random transaction ID.
Uint8List buildStunBindingRequest(Uint8List transactionId) {
  assert(transactionId.length == 12);
  final buffer = ByteData(20);
  buffer.setUint16(0, 0x0001); // Binding Request
  buffer.setUint16(2, 0); // no attributes
  buffer.setUint32(4, _magicCookie);
  final bytes = buffer.buffer.asUint8List();
  bytes.setRange(8, 20, transactionId);
  return bytes;
}

/// Parses a STUN Binding Success Response, returning the external address
/// it reports (via XOR-MAPPED-ADDRESS, falling back to the older
/// MAPPED-ADDRESS) — or `null` if [data] isn't a matching, well-formed
/// response for [expectedTransactionId]. IPv4 only.
StunAddress? parseStunBindingResponse(
  Uint8List data,
  Uint8List expectedTransactionId,
) {
  if (data.length < 20) return null;
  final header = ByteData.sublistView(data, 0, 20);
  if (header.getUint16(0) != 0x0101) return null; // not a Success Response

  final transactionId = data.sublist(8, 20);
  for (var i = 0; i < 12; i++) {
    if (transactionId[i] != expectedTransactionId[i]) return null;
  }

  final messageLength = header.getUint16(2);
  var offset = 20;
  final end = min(20 + messageLength, data.length);
  while (offset + 4 <= end) {
    final attrHeader = ByteData.sublistView(data, offset, offset + 4);
    final attrType = attrHeader.getUint16(0);
    final attrLength = attrHeader.getUint16(2);
    final valueStart = offset + 4;
    final valueEnd = valueStart + attrLength;
    if (valueEnd > data.length) break;

    if (attrType == 0x0020 && attrLength >= 8) {
      final value = ByteData.sublistView(data, valueStart, valueEnd);
      final port = value.getUint16(2) ^ (_magicCookie >> 16);
      final addressInt = value.getUint32(4) ^ _magicCookie;
      return StunAddress(_ipv4ToString(addressInt), port);
    }
    if (attrType == 0x0001 && attrLength >= 8) {
      final value = ByteData.sublistView(data, valueStart, valueEnd);
      final port = value.getUint16(2);
      final addressInt = value.getUint32(4);
      return StunAddress(_ipv4ToString(addressInt), port);
    }

    // Attributes are padded to a 4-byte boundary.
    final padded = attrLength + ((4 - (attrLength % 4)) % 4);
    offset = valueStart + padded;
  }
  return null;
}

String _ipv4ToString(int value) =>
    '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.${(value >> 8) & 0xFF}.${value & 0xFF}';

/// A minimal STUN client: enough to ask a public STUN server "what
/// address/port does the internet see me as?" — the first step toward UDP
/// hole-punching (Phase 4 NAT traversal, ADR 0021/0022).
class StunClient {
  StunClient({this.timeout = const Duration(seconds: 3)});

  final Duration timeout;
  final Random _random = Random.secure();

  /// Sends a STUN Binding Request from [localPort] to [server]:[stunPort],
  /// returning the external address/port the server observed — or `null`
  /// if it didn't respond within [timeout].
  Future<StunAddress?> discover({
    required int localPort,
    required String server,
    int stunPort = 19302,
  }) async {
    final addresses = await InternetAddress.lookup(
      server,
      type: InternetAddressType.IPv4,
    );
    if (addresses.isEmpty) return null;

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      localPort,
    );
    try {
      final transactionId = Uint8List.fromList(
        List<int>.generate(12, (_) => _random.nextInt(256)),
      );
      socket.send(
        buildStunBindingRequest(transactionId),
        addresses.first,
        stunPort,
      );

      final completer = Completer<StunAddress?>();
      final subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final result = parseStunBindingResponse(datagram.data, transactionId);
        if (!completer.isCompleted) completer.complete(result);
      });

      final result = await completer.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      await subscription.cancel();
      return result;
    } finally {
      socket.close();
    }
  }

  /// Queries each of [servers] independently from the *same* [localPort]
  /// and reports whether they all saw the same external mapping.
  ///
  /// Getting the same mapping regardless of which server is asked is the
  /// signature of a NAT that preserves port mappings regardless of
  /// destination ("cone" — favorable for hole-punching); a different
  /// mapping per server means a symmetric NAT, which can't be
  /// hole-punched without a relay. See ADR 0021.
  Future<NatMappingBehavior> detectMappingBehavior({
    required int localPort,
    required List<(String host, int port)> servers,
  }) async {
    final results = <StunAddress>[];
    for (final (host, port) in servers) {
      final address = await discover(
        localPort: localPort,
        server: host,
        stunPort: port,
      );
      if (address != null) results.add(address);
    }

    if (results.length < 2) return NatMappingBehavior.unknown;
    final consistent = results.every((r) => r == results.first);
    return consistent
        ? NatMappingBehavior.consistent
        : NatMappingBehavior.variesByDestination;
  }
}
