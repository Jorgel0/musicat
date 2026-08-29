import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
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

  group('app-facing routes are restricted to loopback callers', () {
    // A real, non-loopback address this machine actually has -- resolved at
    // test time the same way relay_client.dart's own reconnect-backoff
    // check does (`NetworkInterface.list()`), rather than hard-coding one.
    // `null` means this sandbox genuinely has no such interface, which the
    // tests below treat as "skip this specific check" rather than failing
    // outright.
    Future<String?> findLanAddress() async {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
      return null;
    }

    test('GET /api/v1/federation/friends succeeds via 127.0.0.1 but gets 403 '
        'via a real non-loopback address on this same machine', () async {
      handle = await startMusicatServer(dataDir: dataDir, port: 0);
      final port = handle!.port;

      final loopbackResponse = await http.get(
        Uri.parse('http://127.0.0.1:$port/api/v1/federation/friends'),
      );
      expect(loopbackResponse.statusCode, 200);

      final lanAddress = await findLanAddress();
      if (lanAddress == null) {
        markTestSkipped(
          'No non-loopback network interface available in this sandbox',
        );
        return;
      }

      final lanResponse = await http
          .get(Uri.parse('http://$lanAddress:$port/api/v1/federation/friends'))
          .timeout(const Duration(seconds: 5));
      expect(lanResponse.statusCode, 403);
      expect(jsonDecode(lanResponse.body), {
        'error': 'This endpoint is only reachable from this device itself.',
      });
    });

    test('POST /api/v1/federation/friends (pairing-code redemption) and '
        '/api/v1/sharing/* stay reachable via a non-loopback address -- only '
        'ordinary application errors, never this new 403', () async {
      handle = await startMusicatServer(dataDir: dataDir, port: 0);
      final port = handle!.port;

      final lanAddress = await findLanAddress();
      if (lanAddress == null) {
        markTestSkipped(
          'No non-loopback network interface available in this sandbox',
        );
        return;
      }

      // No real pairing code is supplied, so this fails validation -- the
      // important part is that it's the route's own 400, not requireLocal's
      // 403.
      final friendsResponse = await http
          .post(Uri.parse('http://$lanAddress:$port/api/v1/federation/friends'))
          .timeout(const Duration(seconds: 5));
      expect(friendsResponse.statusCode, 400);

      // No signature headers are sent, so RequestVerifier itself rejects
      // this with 401 -- again, the important part is that it isn't
      // requireLocal's 403.
      final sharingResponse = await http
          .get(
            Uri.parse('http://$lanAddress:$port/api/v1/sharing/shared-tracks'),
          )
          .timeout(const Duration(seconds: 5));
      expect(sharingResponse.statusCode, 401);
    });
  });

  group('app-facing routes are unreachable through the relay tunnel', () {
    // A real RelayHub, served over a real socket -- this exercises the
    // exact same relay wiring startMusicatServer uses in production
    // (RelayClient dialing out to it), not a hand-rolled stand-in.
    late RelayHub hub;
    late HttpServer hubServer;

    setUp(() async {
      hub = RelayHub();
      hubServer = await shelf_io.serve(hub.buildRouter().call, 'localhost', 0);
    });

    tearDown(() async {
      await hubServer.close(force: true);
    });

    test('a request forwarded through the relay to an app-facing route gets '
        '403 -- this is exactly the exposure this fix closes: the relay lets '
        'a node be reached just by knowing its nodeId, and that must never '
        "be enough to reach this device's own app-facing routes", () async {
      final wsUrl = 'ws://localhost:${hubServer.port}/connect';
      handle = await startMusicatServer(
        dataDir: dataDir,
        port: 0,
        relayUrl: wsUrl,
      );
      // Confirms the tunnel really is up before relying on it below --
      // startMusicatServer treats a failed relay connection as
      // non-fatal, so this is the difference between a real test of the
      // tunnel and a vacuously-passing one.
      expect(handle!.relayUrl, wsUrl);
      expect(hub.isConnected(handle!.identity.nodeId), isTrue);

      final tunneledResponse = await http.get(
        Uri.parse(
          'http://localhost:${hubServer.port}/${handle!.identity.nodeId}'
          '/api/v1/federation/friends',
        ),
      );
      expect(tunneledResponse.statusCode, 403);
      expect(jsonDecode(tunneledResponse.body), {
        'error': 'This endpoint is only reachable from this device itself.',
      });
    });

    test('a relay-tunneled request to a genuinely federation-facing route '
        "(sharing) is not affected by this check -- it still reaches that "
        "route's own object-level authz instead", () async {
      final wsUrl = 'ws://localhost:${hubServer.port}/connect';
      handle = await startMusicatServer(
        dataDir: dataDir,
        port: 0,
        relayUrl: wsUrl,
      );
      expect(handle!.relayUrl, wsUrl);

      // No signature headers sent -- RequestVerifier itself rejects this
      // with 401, not requireLocal's 403, proving this route was never
      // wrapped in it.
      final tunneledResponse = await http.get(
        Uri.parse(
          'http://localhost:${hubServer.port}/${handle!.identity.nodeId}'
          '/api/v1/sharing/shared-tracks',
        ),
      );
      expect(tunneledResponse.statusCode, 401);
    });
  });
}
