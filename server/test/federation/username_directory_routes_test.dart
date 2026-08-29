import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// End-to-end coverage for `POST /api/v1/federation/username` and `GET
/// /api/v1/federation/directory/lookup` -- a real [RelayHub], and two real
/// [startMusicatServer] instances (each running its own real [RelayClient]
/// under the hood) standing in for two genuinely separate nodes: one claims
/// a username, the other resolves it, exactly as the app-side "add a friend
/// by username" flow will.
void main() {
  late Directory relayDataDir;
  late RelayHub hub;
  late HttpServer hubServer;
  late String wsUrl;

  late Directory nodeADataDir;
  late Directory nodeBDataDir;
  MusicatServerHandle? nodeA;
  MusicatServerHandle? nodeB;

  setUp(() async {
    relayDataDir = Directory.systemTemp.createTempSync(
      'musicat_username_routes_relay_',
    );
    hub = RelayHub(dataDir: relayDataDir);
    hubServer = await shelf_io.serve(hub.buildRouter().call, 'localhost', 0);
    wsUrl = 'ws://localhost:${hubServer.port}/connect';

    nodeADataDir = Directory.systemTemp.createTempSync(
      'musicat_username_routes_node_a_',
    );
    nodeBDataDir = Directory.systemTemp.createTempSync(
      'musicat_username_routes_node_b_',
    );
  });

  tearDown(() async {
    await nodeA?.close();
    await nodeB?.close();
    await hubServer.close(force: true);
    relayDataDir.deleteSync(recursive: true);
    nodeADataDir.deleteSync(recursive: true);
    nodeBDataDir.deleteSync(recursive: true);
  });

  test('node A claims a username, and node B resolves it to node A\'s real '
      'nodeId through the same relay -- the full "add a friend by username" '
      'address-resolution path', () async {
    nodeA = await startMusicatServer(
      dataDir: nodeADataDir,
      port: 0,
      relayUrl: wsUrl,
    );
    expect(nodeA!.relayUrl, wsUrl);

    nodeB = await startMusicatServer(
      dataDir: nodeBDataDir,
      port: 0,
      relayUrl: wsUrl,
    );
    expect(nodeB!.relayUrl, wsUrl);

    final claimResponse = await http.post(
      Uri.parse('http://127.0.0.1:${nodeA!.port}/api/v1/federation/username'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': 'jorge'}),
    );
    expect(claimResponse.statusCode, 200);
    expect(jsonDecode(claimResponse.body), {'username': 'jorge'});

    final lookupResponse = await http.get(
      Uri.parse(
        'http://127.0.0.1:${nodeB!.port}/api/v1/federation/'
        'directory/lookup?username=jorge',
      ),
    );
    expect(lookupResponse.statusCode, 200);
    expect(jsonDecode(lookupResponse.body), {'nodeId': nodeA!.identity.nodeId});
  });

  test('GET .../directory/lookup 404s a username nobody has claimed', () async {
    nodeB = await startMusicatServer(
      dataDir: nodeBDataDir,
      port: 0,
      relayUrl: wsUrl,
    );
    expect(nodeB!.relayUrl, wsUrl);

    final response = await http.get(
      Uri.parse(
        'http://127.0.0.1:${nodeB!.port}/api/v1/federation/'
        'directory/lookup?username=never-claimed-by-anyone',
      ),
    );
    expect(response.statusCode, 404);
  });

  test('POST .../username fails with 409 when already claimed by a '
      'different node', () async {
    nodeA = await startMusicatServer(
      dataDir: nodeADataDir,
      port: 0,
      relayUrl: wsUrl,
    );
    nodeB = await startMusicatServer(
      dataDir: nodeBDataDir,
      port: 0,
      relayUrl: wsUrl,
    );

    final firstClaim = await http.post(
      Uri.parse('http://127.0.0.1:${nodeA!.port}/api/v1/federation/username'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': 'shared-name'}),
    );
    expect(firstClaim.statusCode, 200);

    final secondClaim = await http.post(
      Uri.parse('http://127.0.0.1:${nodeB!.port}/api/v1/federation/username'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': 'shared-name'}),
    );
    expect(secondClaim.statusCode, 409);
    expect(jsonDecode(secondClaim.body), {'error': 'Username already taken'});
  });

  test(
    'POST .../username fails with 400 on an invalid-format username',
    () async {
      nodeA = await startMusicatServer(
        dataDir: nodeADataDir,
        port: 0,
        relayUrl: wsUrl,
      );

      final response = await http.post(
        Uri.parse('http://127.0.0.1:${nodeA!.port}/api/v1/federation/username'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': 'no'}),
      );
      expect(response.statusCode, 400);
      expect(jsonDecode(response.body), {'error': 'Invalid username format'});
    },
  );

  test('POST .../username fails with 503 when this node has no relay '
      'connected at all', () async {
    nodeA = await startMusicatServer(dataDir: nodeADataDir, port: 0);
    expect(nodeA!.relayUrl, isNull);

    final response = await http.post(
      Uri.parse('http://127.0.0.1:${nodeA!.port}/api/v1/federation/username'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': 'jorge'}),
    );
    expect(response.statusCode, 503);
  });

  test('GET .../directory/lookup fails with 503 when this node has no relay '
      'connected at all', () async {
    nodeB = await startMusicatServer(dataDir: nodeBDataDir, port: 0);
    expect(nodeB!.relayUrl, isNull);

    final response = await http.get(
      Uri.parse(
        'http://127.0.0.1:${nodeB!.port}/api/v1/federation/'
        'directory/lookup?username=jorge',
      ),
    );
    expect(response.statusCode, 503);
  });
}
