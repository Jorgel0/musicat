import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/federation/federation_routes.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/pairing_code_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/nat/udp_puncher.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// A hand-built [HttpConnectionInfo] -- the real one is only ever produced
/// by `shelf_io`'s actual socket listener, which these unit tests never go
/// through (they call the router's handler directly). Standing in for it is
/// what lets these tests simulate "this request arrived on loopback" (or
/// not) for `requireLocal`'s sake -- see require_local.dart.
class _FakeConnectionInfo implements HttpConnectionInfo {
  _FakeConnectionInfo(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 12345;

  @override
  int get localPort => 8080;
}

/// The exact context key `shelf_io`'s real `serve()` attaches to every
/// request it hands off (see shelf_io.dart), and the one `requireLocal`
/// reads.
const _connectionInfoContextKey = 'shelf.io.connection_info';

void main() {
  late Directory serverDir;
  late Directory friendDir;
  late FriendStore friendStore;
  late NodeIdentity friendIdentity;
  late UdpPuncher puncher;
  late Handler handler;

  // Two real Ed25519 identities to pair as. `POST /friends` verifies that a
  // claimed nodeId really is the SHA-256 fingerprint of the public key sent
  // with it (`nodeIdForPublicKey`), so these have to be genuine keypairs --
  // a made-up "friend-1"/"key" pair is exactly what that check exists to
  // reject.
  late Directory peerDirA;
  late Directory peerDirB;
  late String peerA;
  late String peerAKey;
  late String peerB;
  late String peerBKey;

  setUp(() async {
    serverDir = Directory.systemTemp.createTempSync('musicat_fed_routes_');
    friendDir = Directory.systemTemp.createTempSync('musicat_fed_friend_');
    friendStore = FriendStore(serverDir);
    friendIdentity = await NodeIdentityStore(friendDir).loadOrCreate();
    peerDirA = Directory.systemTemp.createTempSync('musicat_fed_peer_a_');
    peerDirB = Directory.systemTemp.createTempSync('musicat_fed_peer_b_');
    final peerIdentityA = await NodeIdentityStore(peerDirA).loadOrCreate();
    final peerIdentityB = await NodeIdentityStore(peerDirB).loadOrCreate();
    peerA = peerIdentityA.nodeId;
    peerAKey = await peerIdentityA.publicKeyBase64();
    peerB = peerIdentityB.nodeId;
    peerBKey = await peerIdentityB.publicKeyBase64();
    final serverIdentity = await NodeIdentityStore(serverDir).loadOrCreate();
    puncher = UdpPuncher(identity: serverIdentity, friendStore: friendStore);
    await puncher.bind();
    handler = buildFederationRouter(
      friendStore,
      RequestVerifier(friendStore),
      PairingCodeStore(),
      puncher,
    ).call;
  });

  tearDown(() async {
    await puncher.close();
    serverDir.deleteSync(recursive: true);
    friendDir.deleteSync(recursive: true);
    peerDirA.deleteSync(recursive: true);
    peerDirB.deleteSync(recursive: true);
  });

  // Every request built by the helpers below simulates the common case
  // these tests otherwise want to exercise -- this device's own app calling
  // its own local server on loopback -- so the `requireLocal`-wrapped
  // routes (see federation_routes.dart) behave the same as before this
  // context existed. The dedicated 'requireLocal' group further below
  // overrides this to prove the restriction itself.
  Map<String, Object> loopbackContext() => {
    _connectionInfoContextKey: _FakeConnectionInfo(
      InternetAddress.loopbackIPv4,
    ),
  };

  Future<Response> post(String path, Object body) async => await handler(
    Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      context: loopbackContext(),
    ),
  );

  Future<Response> get(String path, {Map<String, String>? headers}) async =>
      await handler(
        Request(
          'GET',
          Uri.parse('http://localhost$path'),
          headers: headers,
          context: loopbackContext(),
        ),
      );

  Future<Response> delete(String path) async => await handler(
    Request(
      'DELETE',
      Uri.parse('http://localhost$path'),
      context: loopbackContext(),
    ),
  );

  Future<Response> patch(String path, Object body) async => await handler(
    Request(
      'PATCH',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      context: loopbackContext(),
    ),
  );

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
    String? udpCandidate,
  }) => post('/friends', {
    'code': code ?? '', // caller overrides for the invalid-code cases
    'nodeId': nodeId,
    'publicKeyBase64': publicKeyBase64,
    'address': address,
    'udpCandidate': ?udpCandidate,
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
        nodeId: peerA,
        publicKeyBase64: peerAKey,
        address: 'host:8080',
        code: await newPairingCode(),
      );

      expect(response.statusCode, 201);
      final friend = await friendStore.findByAccountOrDeviceId(peerA);
      expect(friend?.primaryDevice?.address, 'host:8080');
    });

    test('rejects a missing code', () async {
      final response = await post('/friends', {
        'nodeId': peerA,
        'publicKeyBase64': peerAKey,
        'address': 'host:8080',
      });
      expect(response.statusCode, 400);
      expect(await friendStore.findByAccountOrDeviceId(peerA), isNull);
    });

    test('rejects an unknown code', () async {
      final response = await pairAsFriend(
        nodeId: peerA,
        publicKeyBase64: peerAKey,
        address: 'host:8080',
        code: 'not-a-real-code',
      );
      expect(response.statusCode, 403);
      expect(await friendStore.findByAccountOrDeviceId(peerA), isNull);
    });

    test('a code can only be redeemed once', () async {
      final code = await newPairingCode();

      final first = await pairAsFriend(
        nodeId: peerA,
        publicKeyBase64: peerAKey,
        address: 'host:8080',
        code: code,
      );
      final second = await pairAsFriend(
        nodeId: peerB,
        publicKeyBase64: peerBKey,
        address: 'host:8081',
        code: code,
      );

      expect(first.statusCode, 201);
      expect(second.statusCode, 403);
      expect(await friendStore.findByAccountOrDeviceId(peerB), isNull);
    });

    test('rejects a missing address', () async {
      final response = await post('/friends', {
        'code': await newPairingCode(),
        'nodeId': peerA,
        'publicKeyBase64': peerAKey,
      });
      expect(response.statusCode, 400);
    });

    test(
      'stores an optional udpCandidate and echoes this node\'s own',
      () async {
        final response = await pairAsFriend(
          nodeId: peerA,
          publicKeyBase64: peerAKey,
          address: 'host:8080',
          code: await newPairingCode(),
          udpCandidate: '203.0.113.5:41234',
        );

        expect(response.statusCode, 201);
        final body = jsonDecode(await response.readAsString());
        // This node hasn't called refreshCandidate() in the test setup, so
        // its own reported candidate is null -- just checking the key exists
        // with the right shape, not exercising real STUN here (see
        // stun_client_test.dart / ADR 0022 for that).
        expect(body.containsKey('udpCandidate'), isTrue);

        final friend = await friendStore.findByAccountOrDeviceId(peerA);
        expect(friend?.primaryDevice?.udpCandidate, '203.0.113.5:41234');
      },
    );

    test('rejects a non-string udpCandidate', () async {
      final response = await post('/friends', {
        'code': await newPairingCode(),
        'nodeId': peerA,
        'publicKeyBase64': peerAKey,
        'address': 'host:8080',
        'udpCandidate': 12345,
      });
      expect(response.statusCode, 400);
    });
  });

  group('GET /friends', () {
    test('lists registered friends', () async {
      await pairAsFriend(
        nodeId: peerA,
        publicKeyBase64: peerAKey,
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
        nodeId: peerA,
        publicKeyBase64: peerAKey,
        address: 'host:8080',
        code: await newPairingCode(),
      );

      final response = await delete('/friends/$peerA');

      expect(response.statusCode, 204);
      expect(await friendStore.findByAccountOrDeviceId(peerA), isNull);
    });

    test(
      'stops maintaining any active NAT keepalive for that friend',
      () async {
        puncher.startKeepalive(nodeId: peerA, host: '127.0.0.1', port: 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(puncher.isMaintaining(peerA), isTrue);

        await delete('/friends/$peerA');

        expect(puncher.isMaintaining(peerA), isFalse);
      },
    );
  });

  group('PATCH /friends/<nodeId>', () {
    test('sets a local nickname and returns the updated friend', () async {
      await pairAsFriend(
        nodeId: peerA,
        publicKeyBase64: peerAKey,
        address: 'host:8080',
        code: await newPairingCode(),
      );

      final response = await patch('/friends/$peerA', {
        'localNickname': 'Bestie',
      });

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['nodeId'], peerA);
      expect(body['localNickname'], 'Bestie');

      final friend = await friendStore.findByAccountOrDeviceId(peerA);
      expect(friend?.localNickname, 'Bestie');
    });

    test('clears a local nickname when given null', () async {
      await pairAsFriend(
        nodeId: peerA,
        publicKeyBase64: peerAKey,
        address: 'host:8080',
        code: await newPairingCode(),
      );
      await patch('/friends/$peerA', {'localNickname': 'Bestie'});

      final response = await patch('/friends/$peerA', {'localNickname': null});

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['localNickname'], isNull);
    });

    test('returns 404 for an unknown friend', () async {
      final response = await patch('/friends/does-not-exist', {
        'localNickname': 'Bestie',
      });

      expect(response.statusCode, 404);
    });

    test('rejects a non-string localNickname', () async {
      await pairAsFriend(
        nodeId: peerA,
        publicKeyBase64: peerAKey,
        address: 'host:8080',
        code: await newPairingCode(),
      );

      final response = await patch('/friends/$peerA', {'localNickname': 12345});

      expect(response.statusCode, 400);
    });

    test('GET /friends reflects the local nickname afterward', () async {
      await pairAsFriend(
        nodeId: peerA,
        publicKeyBase64: peerAKey,
        address: 'host:8080',
        code: await newPairingCode(),
      );
      await patch('/friends/$peerA', {'localNickname': 'Bestie'});

      final response = await get('/friends');
      final body = jsonDecode(await response.readAsString()) as List<dynamic>;

      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['localNickname'], 'Bestie');
    });
  });

  group('GET /friends/<nodeId>/status', () {
    test('reports not connected for a node never seen', () async {
      final response = await get('/friends/unknown-node/status');
      final body = jsonDecode(await response.readAsString());

      expect(response.statusCode, 200);
      expect(body['connected'], isFalse);
      expect(body['lastSeen'], isNull);
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

  group('requireLocal restricts the app-facing routes', () {
    Future<Response> nonLoopback(String method, String path) async =>
        await handler(
          Request(
            method,
            Uri.parse('http://localhost$path'),
            context: {
              _connectionInfoContextKey: _FakeConnectionInfo(
                InternetAddress('8.8.8.8'),
              ),
            },
          ),
        );

    Future<Response> noConnectionInfo(String method, String path) async =>
        await handler(Request(method, Uri.parse('http://localhost$path')));

    for (final (method, path) in [
      ('POST', '/pairing-codes'),
      ('GET', '/friends'),
      ('DELETE', '/friends/friend-1'),
      ('PATCH', '/friends/friend-1'),
      ('GET', '/friends/friend-1/status'),
    ]) {
      test('$method $path rejects a non-loopback caller with 403', () async {
        final response = await nonLoopback(method, path);
        expect(response.statusCode, 403);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], isNotEmpty);
      });

      test('$method $path rejects a request with no connection info at all '
          '(e.g. relay-tunneled) with 403', () async {
        final response = await noConnectionInfo(method, path);
        expect(response.statusCode, 403);
      });

      test('$method $path succeeds for a loopback caller', () async {
        // These helpers (post/get/delete/patch) already attach loopback
        // connection info -- this just confirms the restriction doesn't
        // also accidentally block the legitimate case.
        final response = switch (method) {
          'POST' => await post(path, {}),
          'GET' => await get(path),
          'DELETE' => await delete(path),
          'PATCH' => await patch(path, {}),
          _ => throw StateError('unexpected method $method'),
        };
        expect(response.statusCode, isNot(403));
      });
    }

    test('POST /friends (pairing-code redemption) is NOT restricted -- a '
        'non-loopback caller reaches the ordinary application logic instead '
        'of getting a 403 from this check', () async {
      final response = await nonLoopback('POST', '/friends');
      // No body was sent, so this fails validation -- the important part
      // is that it's a 400 from the route's own body parsing, not a 403
      // from requireLocal.
      expect(response.statusCode, isNot(403));
    });

    test('GET /ping is NOT restricted -- a non-loopback caller still reaches '
        "RequestVerifier's own check instead of getting a 403 from this "
        'check', () async {
      final response = await nonLoopback('GET', '/ping');
      // No signature headers were sent, so RequestVerifier itself rejects
      // this with 401 -- the important part is that it isn't requireLocal's
      // 403.
      expect(response.statusCode, 401);
    });

    test('a non-loopback caller presenting a key gets 403 when none is '
        'configured at all (the default -- this handler was built without '
        'appApiKey)', () async {
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/friends'),
          headers: {'X-Api-Key': 'some-key'},
          context: {
            _connectionInfoContextKey: _FakeConnectionInfo(
              InternetAddress('8.8.8.8'),
            ),
          },
        ),
      );
      expect(response.statusCode, 403);
    });
  });

  group('requireLocal MUSICAT_APP_API_KEY opt-in', () {
    late Handler handlerWithKey;

    setUp(() {
      handlerWithKey = buildFederationRouter(
        friendStore,
        RequestVerifier(friendStore),
        PairingCodeStore(),
        puncher,
        appApiKey: 'correct-key',
      ).call;
    });

    Future<Response> nonLoopbackWithKey(
      String method,
      String path, {
      Map<String, String>? headers,
    }) async => await handlerWithKey(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: headers,
        context: {
          _connectionInfoContextKey: _FakeConnectionInfo(
            InternetAddress('8.8.8.8'),
          ),
        },
      ),
    );

    test('a non-loopback caller with the correct X-Api-Key reaches the '
        'route instead of getting requireLocal\'s 403', () async {
      final response = await nonLoopbackWithKey(
        'GET',
        '/friends',
        headers: {'X-Api-Key': 'correct-key'},
      );
      expect(response.statusCode, isNot(403));
    });

    test(
      'a non-loopback caller with a missing X-Api-Key still gets 403',
      () async {
        final response = await nonLoopbackWithKey('GET', '/friends');
        expect(response.statusCode, 403);
      },
    );

    test('a non-loopback caller with the wrong X-Api-Key gets 403', () async {
      final response = await nonLoopbackWithKey(
        'GET',
        '/friends',
        headers: {'X-Api-Key': 'wrong-key'},
      );
      expect(response.statusCode, 403);
    });

    test('a loopback caller succeeds with no key needed at all, even though '
        'one is configured', () async {
      final response = await handlerWithKey(
        Request(
          'GET',
          Uri.parse('http://localhost/friends'),
          context: loopbackContext(),
        ),
      );
      expect(response.statusCode, isNot(403));
    });
  });
}
