import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  MusicatServerHandle? handle;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('musicat_server_test_');
  });

  tearDown(() async {
    await handle?.close();
    handle = null;
    dataDir.deleteSync(recursive: true);
  });

  test('root returns a health check', () async {
    handle = await startMusicatServer(dataDir: dataDir, port: 0);

    final response = await http.get(
      Uri.parse('http://localhost:${handle!.port}/'),
    );
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'status': 'ok'});
  });

  test('exposes the node identity', () async {
    handle = await startMusicatServer(dataDir: dataDir, port: 0);

    final response = await http.get(
      Uri.parse('http://localhost:${handle!.port}/api/v1/node'),
    );
    expect(response.statusCode, 200);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    expect(body['nodeId'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(body['nodeId'], handle!.identity.nodeId);
  });

  test('unknown routes 404', () async {
    handle = await startMusicatServer(dataDir: dataDir, port: 0);

    final response = await http.get(
      Uri.parse('http://localhost:${handle!.port}/foobar'),
    );
    expect(response.statusCode, 404);
  });

  test(
    'port: 0 resolves to a real OS-assigned port, not the literal 0',
    () async {
      handle = await startMusicatServer(dataDir: dataDir, port: 0);

      expect(handle!.port, isNot(0));
      expect(handle!.port, greaterThan(0));
    },
  );

  test('close() actually stops the server -- a request after it fails to '
      'connect', () async {
    handle = await startMusicatServer(dataDir: dataDir, port: 0);
    final port = handle!.port;

    await handle!.close();
    handle = null;

    await expectLater(
      http.get(Uri.parse('http://localhost:$port/')),
      throwsA(isA<Object>()),
    );
  });

  test('node identity persists across two separate startMusicatServer calls '
      'pointed at the same dataDir (ADR 0015)', () async {
    final first = await startMusicatServer(dataDir: dataDir, port: 0);
    final firstNodeId = first.identity.nodeId;
    await first.close();

    final second = await startMusicatServer(dataDir: dataDir, port: 0);
    handle = second;

    expect(second.identity.nodeId, firstNodeId);
  });
}
