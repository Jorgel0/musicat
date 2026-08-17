import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/federation/federation_routes.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/pairing_code_store.dart';
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
      PairingCodeStore(),
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

  Future<String> newPairingCode() async {
    final response = await post('/pairing-codes', {});
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    return body['code'] as String;
  }

  Future<Response> pairAsFriend({
    required String nodeId,
    required String publicKeyBase64,
    required String address,
    String? code,
  }) => post('/friends', {
    'code': code ?? '', // caller overrides for the invalid-code cases
    'nodeId': nodeId,
    'publicKeyBase64': publicKeyBase64,
    'address': address,
  });

  group('POST /pairing-codes', () {
    test('generates a code', () async {
      final response = await post('/pairing-codes', {});
      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      expect(body['code'], isNotEmpty);
    });
  });

  group('POST /friends', () {
    test('registers a friend with a valid pairing code', () async {
      final response = await pairAsFriend(
        nodeId: 'friend-1',
        publicKeyBase64: 'key',
        address: 'host:8080',
        code: await newPairingCode(),
      );

      expect(response.statusCode, 201);
      final friend = await friendStore.findByNodeId('friend-1');
      expect(friend?.address, 'host:8080');
    });

    test('rejects a missing code', () async {
      final response = await post('/friends', {
        'nodeId': 'friend-1',
        'publicKeyBase64': 'key',
        'address': 'host:8080',
      });
      expect(response.statusCode, 400);
      expect(await friendStore.findByNodeId('friend-1'), isNull);
    });

    test('rejects an unknown code', () async {
      final response = await pairAsFriend(
        nodeId: 'friend-1',
        publicKeyBase64: 'key',
        address: 'host:8080',
        code: 'not-a-real-code',
      );
      expect(response.statusCode, 403);
      expect(await friendStore.findByNodeId('friend-1'), isNull);
    });

    test('a code can only be redeemed once', () async {
      final code = await newPairingCode();

      final first = await pairAsFriend(
        nodeId: 'friend-1',
        publicKeyBase64: 'key',
        address: 'host:8080',
        code: code,
      );
      final second = await pairAsFriend(
        nodeId: 'friend-2',
        publicKeyBase64: 'key',
        address: 'host:8081',
        code: code,
      );

      expect(first.statusCode, 201);
      expect(second.statusCode, 403);
      expect(await friendStore.findByNodeId('friend-2'), isNull);
    });

    test('rejects a missing address', () async {
      final response = await post('/friends', {
        'code': await newPairingCode(),
        'nodeId': 'friend-1',
        'publicKeyBase64': 'key',
      });
      expect(response.statusCode, 400);
    });
  });

  group('GET /friends', () {
    test('lists registered friends', () async {
      await pairAsFriend(
        nodeId: 'friend-1',
        publicKeyBase64: 'key',
        address: 'host:8080',
        code: await newPairingCode(),
      );

      final response = await get('/friends');
      final body = jsonDecode(await response.readAsString()) as List<dynamic>;
      expect(body, hasLength(1));
    });
  });

  group('DELETE /friends/<nodeId>', () {
    test('revokes a friend', () async {
      await pairAsFriend(
        nodeId: 'friend-1',
        publicKeyBase64: 'key',
        address: 'host:8080',
        code: await newPairingCode(),
      );

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
      await pairAsFriend(
        nodeId: friendIdentity.nodeId,
        publicKeyBase64: await friendIdentity.publicKeyBase64(),
        address: 'friend.example:8080',
        code: await newPairingCode(),
      );

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
      await pairAsFriend(
        nodeId: friendIdentity.nodeId,
        publicKeyBase64: await friendIdentity.publicKeyBase64(),
        address: 'friend.example:8080',
        code: await newPairingCode(),
      );
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
