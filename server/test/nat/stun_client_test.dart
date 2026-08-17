import 'dart:typed_data';

import 'package:musicat_server/src/nat/stun_client.dart';
import 'package:test/test.dart';

const _magicCookie = 0x2112A442;

/// Hand-builds a STUN Binding Success Response with an XOR-MAPPED-ADDRESS
/// attribute, independently of the client's own encoding logic (straight
/// from the RFC 5389 formulas), so the test doesn't just mirror whatever
/// the implementation happens to do.
Uint8List _xorMappedAddressResponse({
  required Uint8List transactionId,
  required List<int> ipv4,
  required int port,
}) {
  final xport = port ^ (_magicCookie >> 16);
  final addressInt =
      (ipv4[0] << 24) | (ipv4[1] << 16) | (ipv4[2] << 8) | ipv4[3];
  final xaddress = addressInt ^ _magicCookie;

  final attribute = ByteData(12);
  attribute.setUint16(0, 0x0020); // XOR-MAPPED-ADDRESS
  attribute.setUint16(2, 8); // attribute value length
  attribute.setUint8(4, 0); // reserved
  attribute.setUint8(5, 0x01); // family: IPv4
  attribute.setUint16(6, xport);
  attribute.setUint32(8, xaddress);

  final header = ByteData(20);
  header.setUint16(0, 0x0101); // Binding Success Response
  header.setUint16(2, 12); // attribute bytes that follow
  header.setUint32(4, _magicCookie);
  final headerBytes = header.buffer.asUint8List()
    ..setRange(8, 20, transactionId);

  return Uint8List.fromList([
    ...headerBytes,
    ...attribute.buffer.asUint8List(),
  ]);
}

Uint8List _mappedAddressResponse({
  required Uint8List transactionId,
  required List<int> ipv4,
  required int port,
}) {
  // MAPPED-ADDRESS value is: reserved(1) family(1) port(2) address(4) = 8 bytes.
  final value = ByteData(8);
  value.setUint8(0, 0);
  value.setUint8(1, 0x01);
  value.setUint16(2, port);
  value.setUint8(4, ipv4[0]);
  value.setUint8(5, ipv4[1]);
  value.setUint8(6, ipv4[2]);
  value.setUint8(7, ipv4[3]);

  final attrHeader = ByteData(4);
  attrHeader.setUint16(0, 0x0001);
  attrHeader.setUint16(2, 8);

  final header = ByteData(20);
  header.setUint16(0, 0x0101);
  header.setUint16(2, 12); // 4-byte attr header + 8-byte value
  header.setUint32(4, _magicCookie);
  final headerBytes = header.buffer.asUint8List()
    ..setRange(8, 20, transactionId);

  return Uint8List.fromList([
    ...headerBytes,
    ...attrHeader.buffer.asUint8List(),
    ...value.buffer.asUint8List(),
  ]);
}

void main() {
  final transactionId = Uint8List.fromList(List.generate(12, (i) => i + 1));

  group('buildStunBindingRequest', () {
    test('produces a well-formed 20-byte Binding Request header', () {
      final bytes = buildStunBindingRequest(transactionId);
      final header = ByteData.sublistView(bytes);

      expect(bytes.length, 20);
      expect(header.getUint16(0), 0x0001); // Binding Request
      expect(header.getUint16(2), 0); // no attributes
      expect(header.getUint32(4), _magicCookie);
      expect(bytes.sublist(8, 20), transactionId);
    });
  });

  group('parseStunBindingResponse', () {
    test('parses a XOR-MAPPED-ADDRESS response', () {
      final response = _xorMappedAddressResponse(
        transactionId: transactionId,
        ipv4: [203, 0, 113, 5],
        port: 54321,
      );

      final address = parseStunBindingResponse(response, transactionId);

      expect(address, isNotNull);
      expect(address!.address, '203.0.113.5');
      expect(address.port, 54321);
    });

    test('parses a MAPPED-ADDRESS response (older server fallback)', () {
      final response = _mappedAddressResponse(
        transactionId: transactionId,
        ipv4: [198, 51, 100, 42],
        port: 12345,
      );

      final address = parseStunBindingResponse(response, transactionId);

      expect(address, isNotNull);
      expect(address!.address, '198.51.100.42');
      expect(address.port, 12345);
    });

    test('rejects a response for a different transaction id', () {
      final otherTransactionId = Uint8List.fromList(
        List.generate(12, (i) => 99 - i),
      );
      final response = _xorMappedAddressResponse(
        transactionId: otherTransactionId,
        ipv4: [203, 0, 113, 5],
        port: 54321,
      );

      expect(parseStunBindingResponse(response, transactionId), isNull);
    });

    test('rejects a message that is not a Binding Success Response', () {
      final response = _xorMappedAddressResponse(
        transactionId: transactionId,
        ipv4: [203, 0, 113, 5],
        port: 54321,
      );
      // Corrupt the message type (offset 0-1) to something else.
      response[1] = 0x11;

      expect(parseStunBindingResponse(response, transactionId), isNull);
    });

    test('rejects data shorter than a STUN header', () {
      expect(parseStunBindingResponse(Uint8List(10), transactionId), isNull);
    });
  });
}
