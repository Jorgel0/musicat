import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';
import 'package:test/test.dart';

void main() {
  final port = '8080';
  final host = 'http://0.0.0.0:$port';
  late Directory dataDir;
  late Process p;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('musicat_server_test_');
    p = await Process.start(
      'dart',
      ['run', 'bin/server.dart'],
      environment: {'PORT': port, 'MUSICAT_DATA_DIR': dataDir.path},
    );
    // Wait for the server to actually be listening, not just for its first
    // line of output (it prints the node identity before that).
    await p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('Server listening'));
  });

  tearDown(() {
    p.kill();
    dataDir.deleteSync(recursive: true);
  });

  test('root returns a health check', () async {
    final response = await get(Uri.parse('$host/'));
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'status': 'ok'});
  });

  test('exposes the node identity', () async {
    final response = await get(Uri.parse('$host/api/v1/node'));
    expect(response.statusCode, 200);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    expect(body['nodeId'], matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('unknown routes 404', () async {
    final response = await get(Uri.parse('$host/foobar'));
    expect(response.statusCode, 404);
  });
}
