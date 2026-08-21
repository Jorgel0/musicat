import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/relay/relay_client.dart';
import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  late Directory identityDir;
  late NodeIdentity identity;
  late RelayHub hub;
  late HttpServer server;
  late String wsUrl;
  late String httpUrl;
  late RelayClient client;

  setUp(() async {
    identityDir = Directory.systemTemp.createTempSync('musicat_relay_client_');
    identity = await NodeIdentityStore(identityDir).loadOrCreate();
    hub = RelayHub();
    server = await shelf_io.serve(hub.buildRouter().call, 'localhost', 0);
    wsUrl = 'ws://localhost:${server.port}/connect';
    httpUrl = 'http://localhost:${server.port}';
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
    identityDir.deleteSync(recursive: true);
  });

  test('a real request forwarded through the relay reaches the local handler '
      'exactly like a direct one would', () async {
    final localRouter = Router()
      ..get(
        '/api/v1/node',
        (Request request) => Response.ok(
          jsonEncode({'nodeId': identity.nodeId}),
          headers: {'content-type': 'application/json'},
        ),
      );
    client = RelayClient(identity: identity, localHandler: localRouter.call);

    final connected = await client.connect(wsUrl);
    expect(connected, isTrue);
    expect(client.isConnected, isTrue);
    expect(hub.isConnected(identity.nodeId), isTrue);

    final response = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );

    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'nodeId': identity.nodeId});
  });

  test("the local handler's own object-level authz still applies -- the relay "
      'never bypasses it', () async {
    final localRouter = Router()
      ..get(
        '/protected',
        (Request request) => request.headers['x-secret'] == 'right'
            ? Response.ok('ok')
            : Response(403),
      );
    client = RelayClient(identity: identity, localHandler: localRouter.call);
    await client.connect(wsUrl);

    final denied = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/protected'),
    );
    expect(denied.statusCode, 403);

    final allowed = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/protected'),
      headers: {'x-secret': 'right'},
    );
    expect(allowed.statusCode, 200);
  });

  test('forwards POST bodies intact', () async {
    final localRouter = Router()
      ..post('/echo', (Request request) async {
        final body = await request.readAsString();
        return Response.ok(body);
      });
    client = RelayClient(identity: identity, localHandler: localRouter.call);
    await client.connect(wsUrl);

    final response = await http.post(
      Uri.parse('$httpUrl/${identity.nodeId}/echo'),
      body: 'hello from the other side',
    );
    expect(response.statusCode, 200);
    expect(response.body, 'hello from the other side');
  });

  test(
    'connect() returns false, not an exception, for an unreachable relay',
    () async {
      client = RelayClient(
        identity: identity,
        localHandler: (request) async => Response.ok('unused'),
      );
      final connected = await client.connect('ws://localhost:1/connect');
      expect(connected, isFalse);
      expect(client.isConnected, isFalse);
    },
  );

  test('close() disconnects and the hub stops routing to it', () async {
    final localRouter = Router()
      ..get('/api/v1/node', (Request request) => Response.ok('ok'));
    client = RelayClient(identity: identity, localHandler: localRouter.call);
    await client.connect(wsUrl);
    expect(hub.isConnected(identity.nodeId), isTrue);

    await client.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hub.isConnected(identity.nodeId), isFalse);

    final response = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );
    expect(response.statusCode, 502);
  });
}
