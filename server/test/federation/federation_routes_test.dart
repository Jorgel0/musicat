import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/federation/federation_routes.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory serverDir;
  late Directory friendDir;
  late FriendStore friendStore;
  late NodeIdentity friendIdentity;
  late Handler handler;

  setUp(() async {
    serverDir = Directory.systemTemp.createTempSync('musicat_fed_routes_');
    friendDir = Directory.systemTemp.createTempSync('musicat_fed_friend_');
    friendStore = FriendStore(serverDir);
    friendIdentity = await NodeIdentityStore(friendDir).loadOrCreate();
    handler = buildFederationRouter(
      friendStore,
      RequestVerifier(friendStore),
    ).call;
  });

  tearDown(() {
    serverDir.deleteSync(recursive: true);
    friendDir.deleteSync(recursive: true);
  });

  Future<Response> post(String path, Object body) async => await handler(
    Request('POST', Uri.parse('http://localhost$path'), body: jsonEncode(body)),
  );

  Future<Response> get(String path, {Map<String, String>? headers}) async =>
      await handler(
        Request('GET', Uri.parse('http://localhost$path'), headers: headers),
      );

  Future<Response> delete(String path) async =>
      await handler(Request('DELETE', Uri.parse('http://localhost$path')));

  group('POST /friends', () {
    test('registers a friend', () async {
      final response = await post('/friends', {
        'nodeId': 'friend-1',
        'publicKeyBase64': 'key',
        'address': 'host:8080',
      });

      expect(response.statusCode, 201);
      final friend = await friendStore.findByNodeId('friend-1');
      expect(friend?.address, 'host:8080');
    });

    test('rejects a missing address', () async {
      final response = await post('/friends', {
        'nodeId': 'friend-1',
        'publicKeyBase64': 'key',
      });
      expect(response.statusCode, 400);
    });
  });

  group('GET /friends', () {
    test('lists registered friends', () async {
      await post('/friends', {
        'nodeId': 'friend-1',
        'publicKeyBase64': 'key',
        'address': 'host:8080',
      });

      final response = await get('/friends');
      final body = jsonDecode(await response.readAsString()) as List<dynamic>;
      expect(body, hasLength(1));
    });
  });

  group('DELETE /friends/<nodeId>', () {
    test('revokes a friend', () async {
      await post('/friends', {
        'nodeId': 'friend-1',
        'publicKeyBase64': 'key',
        'address': 'host:8080',
      });

      final response = await delete('/friends/friend-1');

      expect(response.statusCode, 204);
      expect(await friendStore.findByNodeId('friend-1'), isNull);
    });
  });

  group('GET /ping', () {
    test('rejects a request with no signature headers', () async {
      final response = await get('/ping');
      expect(response.statusCode, 401);
    });

    test('rejects a request from an unregistered node', () async {
      final headers = await RequestSigner(
        friendIdentity,
      ).sign(method: 'GET', path: '/ping');

      final response = await get(
        '/ping',
        headers: {
          'x-node-id': headers['X-Node-Id']!,
          'x-timestamp': headers['X-Timestamp']!,
          'x-signature': headers['X-Signature']!,
        },
      );

      expect(response.statusCode, 403);
    });

    test('accepts a validly signed request from a registered friend', () async {
      await post('/friends', {
        'nodeId': friendIdentity.nodeId,
        'publicKeyBase64': await friendIdentity.publicKeyBase64(),
        'address': 'friend.example:8080',
      });

      final headers = await RequestSigner(
        friendIdentity,
      ).sign(method: 'GET', path: '/ping');

      final response = await get(
        '/ping',
        headers: {
          'x-node-id': headers['X-Node-Id']!,
          'x-timestamp': headers['X-Timestamp']!,
          'x-signature': headers['X-Signature']!,
        },
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['pong'], isTrue);
    });

    test('rejects a previously-valid friend after revocation', () async {
      await post('/friends', {
        'nodeId': friendIdentity.nodeId,
        'publicKeyBase64': await friendIdentity.publicKeyBase64(),
        'address': 'friend.example:8080',
      });
      final headers = await RequestSigner(
        friendIdentity,
      ).sign(method: 'GET', path: '/ping');

      await delete('/friends/${friendIdentity.nodeId}');

      final response = await get(
        '/ping',
        headers: {
          'x-node-id': headers['X-Node-Id']!,
          'x-timestamp': headers['X-Timestamp']!,
          'x-signature': headers['X-Signature']!,
        },
      );

      expect(response.statusCode, 403);
    });
  });
}
