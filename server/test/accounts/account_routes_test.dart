import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/accounts/login_nonce_store.dart';
import 'package:musicat_server/src/accounts/login_rate_limiter.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  late Directory accountsDataDir;
  late Directory friendRequestsDataDir;
  late AccountStore accountStore;
  late FriendRequestStore friendRequestStore;
  late LoginRateLimiter rateLimiter;
  late HttpServer server;
  late String baseUrl;
  final identityDirs = <Directory>[];

  setUp(() async {
    accountsDataDir = Directory.systemTemp.createTempSync(
      'musicat_account_routes_accounts_',
    );
    friendRequestsDataDir = Directory.systemTemp.createTempSync(
      'musicat_account_routes_friend_requests_',
    );
    accountStore = AccountStore(accountsDataDir);
    friendRequestStore = FriendRequestStore(friendRequestsDataDir);
    // A small threshold/duration so the rate-limiting tests below don't
    // need to make dozens of real (Argon2id-hashing) HTTP round trips or
    // wait out a long real lockout.
    rateLimiter = LoginRateLimiter(
      maxAttempts: 3,
      lockoutDuration: const Duration(milliseconds: 300),
    );

    final router = buildAccountRouter(
      accountStore,
      friendRequestStore,
      loginNonceStore: LoginNonceStore(),
      loginRateLimiter: rateLimiter,
    );
    server = await shelf_io.serve(router.call, 'localhost', 0);
    baseUrl = 'http://localhost:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    accountsDataDir.deleteSync(recursive: true);
    friendRequestsDataDir.deleteSync(recursive: true);
    for (final dir in identityDirs) {
      dir.deleteSync(recursive: true);
    }
    identityDirs.clear();
  });

  Future<NodeIdentity> newIdentity() async {
    final dir = Directory.systemTemp.createTempSync(
      'musicat_account_identity_',
    );
    identityDirs.add(dir);
    return NodeIdentityStore(dir).loadOrCreate();
  }

  Future<List<int>> startLogin(String username) async {
    final response = await http.post(
      Uri.parse('$baseUrl/login/start'),
      body: jsonEncode({'username': username}),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return base64Decode(body['nonceBase64'] as String);
  }

  Future<http.Response> completeLogin({
    required String username,
    required String password,
    required NodeIdentity identity,
    List<int>? nonceOverride,
  }) async {
    final nonce = nonceOverride ?? await startLogin(username);
    final signature = await Ed25519().sign(nonce, keyPair: identity.keyPair);
    return http.post(
      Uri.parse('$baseUrl/login/complete'),
      body: jsonEncode({
        'username': username,
        'password': password,
        'nodeId': identity.nodeId,
        'publicKeyBase64': await identity.publicKeyBase64(),
        'signatureOverNonce': base64Encode(signature.bytes),
      }),
    );
  }

  Future<String> signUp(
    String username,
    String password,
    NodeIdentity identity,
  ) async {
    final response = await completeLogin(
      username: username,
      password: password,
      identity: identity,
    );
    expect(response.statusCode, 201);
    return (jsonDecode(response.body) as Map<String, dynamic>)['accountId']
        as String;
  }

  Future<Map<String, String>> signedHeaders(
    NodeIdentity identity, {
    required String method,
    required String path,
    String body = '',
  }) => RequestSigner(identity).sign(method: method, path: path, body: body);

  group('POST /login/start', () {
    test('returns a nonce', () async {
      final response = await http.post(
        Uri.parse('$baseUrl/login/start'),
        body: jsonEncode({'username': 'alice'}),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['nonceBase64'], isNotEmpty);
    });

    test('responds identically (shape and status) whether the username '
        'already has an account or not -- the account-enumeration concern '
        'this endpoint is designed around', () async {
      final identity = await newIdentity();
      await signUp('alice', 'hunter2', identity);

      final existing = await http.post(
        Uri.parse('$baseUrl/login/start'),
        body: jsonEncode({'username': 'alice'}),
      );
      final neverRegistered = await http.post(
        Uri.parse('$baseUrl/login/start'),
        body: jsonEncode({'username': 'never-registered-user'}),
      );

      expect(existing.statusCode, neverRegistered.statusCode);
      expect(
        (jsonDecode(existing.body) as Map<String, dynamic>).keys,
        (jsonDecode(neverRegistered.body) as Map<String, dynamic>).keys,
      );
    });

    test('rejects a missing username', () async {
      final response = await http.post(
        Uri.parse('$baseUrl/login/start'),
        body: jsonEncode({}),
      );
      expect(response.statusCode, 400);
    });
  });

  group('POST /login/complete -- signup and multi-device login', () {
    test(
      'signup for a brand-new username succeeds and links the device',
      () async {
        final identity = await newIdentity();

        final response = await completeLogin(
          username: 'alice',
          password: 'hunter2',
          identity: identity,
        );

        expect(response.statusCode, 201);
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        expect(body['created'], isTrue);
        expect(body['username'], 'alice');
        final devices = body['devices'] as List<dynamic>;
        expect(devices, hasLength(1));
        expect(devices.single['nodeId'], identity.nodeId);
      },
    );

    test(
      'a second login/complete for the same username, correct password, '
      'and a different device links that device too (multi-device)',
      () async {
        final identityA = await newIdentity();
        final identityB = await newIdentity();

        await signUp('alice', 'hunter2', identityA);

        final second = await completeLogin(
          username: 'alice',
          password: 'hunter2',
          identity: identityB,
        );

        expect(second.statusCode, 200);
        final body = jsonDecode(second.body) as Map<String, dynamic>;
        expect(body['created'], isFalse);
        final nodeIds = (body['devices'] as List<dynamic>)
            .map((d) => (d as Map<String, dynamic>)['nodeId'])
            .toSet();
        expect(nodeIds, {identityA.nodeId, identityB.nodeId});
      },
    );

    test('a wrong password for an existing account fails and does not create '
        'a duplicate account or corrupt the existing one', () async {
      final identityA = await newIdentity();
      await signUp('alice', 'correct-password', identityA);

      final identityB = await newIdentity();
      final wrong = await completeLogin(
        username: 'alice',
        password: 'wrong-password',
        identity: identityB,
      );
      expect(wrong.statusCode, 401);

      final account = await accountStore.findByUsername('alice');
      expect(account!.devices, hasLength(1));
      expect(account.devices.single.nodeId, identityA.nodeId);

      final retryWithRealPassword = await completeLogin(
        username: 'alice',
        password: 'correct-password',
        identity: identityB,
      );
      expect(retryWithRealPassword.statusCode, 200);
    });

    test('rejects an invalid-format username', () async {
      final identity = await newIdentity();
      final response = await completeLogin(
        username: 'ab',
        password: 'hunter2',
        identity: identity,
      );
      expect(response.statusCode, 400);
    });
  });

  group('POST /login/complete -- identity proof', () {
    test('a mismatched nodeId is rejected even with an otherwise-valid '
        'signature, and creates no account', () async {
      final identity = await newIdentity();
      final nonce = await startLogin('alice');
      final signature = await Ed25519().sign(nonce, keyPair: identity.keyPair);

      final response = await http.post(
        Uri.parse('$baseUrl/login/complete'),
        body: jsonEncode({
          'username': 'alice',
          'password': 'hunter2',
          'nodeId': 'not-the-real-fingerprint',
          'publicKeyBase64': await identity.publicKeyBase64(),
          'signatureOverNonce': base64Encode(signature.bytes),
        }),
      );

      expect(response.statusCode, 401);
      expect(await accountStore.findByUsername('alice'), isNull);
    });

    test('signing the wrong nonce (not the one issued by login/start) is '
        'rejected', () async {
      final identity = await newIdentity();
      await startLogin('alice');
      final wrongNonce = List<int>.filled(24, 7);
      final signature = await Ed25519().sign(
        wrongNonce,
        keyPair: identity.keyPair,
      );

      final response = await http.post(
        Uri.parse('$baseUrl/login/complete'),
        body: jsonEncode({
          'username': 'alice',
          'password': 'hunter2',
          'nodeId': identity.nodeId,
          'publicKeyBase64': await identity.publicKeyBase64(),
          'signatureOverNonce': base64Encode(signature.bytes),
        }),
      );

      expect(response.statusCode, 401);
      expect(await accountStore.findByUsername('alice'), isNull);
    });

    test('a nonce can only be redeemed once', () async {
      final identityA = await newIdentity();
      final nonce = await startLogin('alice');
      final first = await completeLogin(
        username: 'alice',
        password: 'hunter2',
        identity: identityA,
        nonceOverride: nonce,
      );
      expect(first.statusCode, 201);

      final identityB = await newIdentity();
      final signature = await Ed25519().sign(nonce, keyPair: identityB.keyPair);
      final reused = await http.post(
        Uri.parse('$baseUrl/login/complete'),
        body: jsonEncode({
          'username': 'alice',
          'password': 'hunter2',
          'nodeId': identityB.nodeId,
          'publicKeyBase64': await identityB.publicKeyBase64(),
          'signatureOverNonce': base64Encode(signature.bytes),
        }),
      );
      expect(reused.statusCode, 401);
    });

    test('an expired nonce is rejected', () async {
      final router = buildAccountRouter(
        accountStore,
        friendRequestStore,
        loginNonceStore: LoginNonceStore(ttl: const Duration(milliseconds: 20)),
      );
      final expiringServer = await shelf_io.serve(router.call, 'localhost', 0);
      addTearDown(() => expiringServer.close(force: true));
      final expiringBaseUrl = 'http://localhost:${expiringServer.port}';

      final startResponse = await http.post(
        Uri.parse('$expiringBaseUrl/login/start'),
        body: jsonEncode({'username': 'alice'}),
      );
      final nonce = base64Decode(
        (jsonDecode(startResponse.body) as Map<String, dynamic>)['nonceBase64']
            as String,
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final identity = await newIdentity();
      final signature = await Ed25519().sign(nonce, keyPair: identity.keyPair);
      final response = await http.post(
        Uri.parse('$expiringBaseUrl/login/complete'),
        body: jsonEncode({
          'username': 'alice',
          'password': 'hunter2',
          'nodeId': identity.nodeId,
          'publicKeyBase64': await identity.publicKeyBase64(),
          'signatureOverNonce': base64Encode(signature.bytes),
        }),
      );
      expect(response.statusCode, 401);
    });
  });

  group('POST /login/complete -- rate limiting', () {
    test('enough consecutive wrong-password attempts locks out further '
        'attempts, and a correct password during the lockout still fails '
        'until it expires', () async {
      final owner = await newIdentity();
      await signUp('alice', 'correct-password', owner);

      final attacker = await newIdentity();
      for (var i = 0; i < 3; i++) {
        final response = await completeLogin(
          username: 'alice',
          password: 'wrong-password',
          identity: attacker,
        );
        expect(response.statusCode, 401);
      }

      final lockedOutWrong = await completeLogin(
        username: 'alice',
        password: 'wrong-password',
        identity: attacker,
      );
      expect(lockedOutWrong.statusCode, 429);

      final lockedOutRight = await completeLogin(
        username: 'alice',
        password: 'correct-password',
        identity: attacker,
      );
      expect(lockedOutRight.statusCode, 429);

      await Future<void>.delayed(const Duration(milliseconds: 350));

      final afterExpiry = await completeLogin(
        username: 'alice',
        password: 'correct-password',
        identity: attacker,
      );
      expect(afterExpiry.statusCode, 200);
    });
  });

  group('GET /by-device/<nodeId>', () {
    test('resolves a linked device to its accountId', () async {
      final identity = await newIdentity();
      final accountId = await signUp('alice', 'hunter2', identity);

      final response = await http.get(
        Uri.parse('$baseUrl/by-device/${identity.nodeId}'),
      );
      expect(response.statusCode, 200);
      expect(
        (jsonDecode(response.body) as Map<String, dynamic>)['accountId'],
        accountId,
      );
    });

    test('404s a nodeId that was never linked', () async {
      final response = await http.get(
        Uri.parse('$baseUrl/by-device/never-linked'),
      );
      expect(response.statusCode, 404);
    });
  });

  group('DELETE /<accountId>/devices/<nodeId>', () {
    test(
      'a linked device can unlink another device on the same account',
      () async {
        final identityA = await newIdentity();
        final identityB = await newIdentity();
        final accountId = await signUp('alice', 'hunter2', identityA);
        await completeLogin(
          username: 'alice',
          password: 'hunter2',
          identity: identityB,
        );

        final path = '/$accountId/devices/${identityB.nodeId}';
        final headers = await signedHeaders(
          identityA,
          method: 'DELETE',
          path: path,
        );
        final response = await http.delete(
          Uri.parse('$baseUrl$path'),
          headers: headers,
        );

        expect(response.statusCode, 204);
        final lookup = await http.get(
          Uri.parse('$baseUrl/by-device/${identityB.nodeId}'),
        );
        expect(lookup.statusCode, 404);
      },
    );

    test('a device can unlink itself', () async {
      final identityA = await newIdentity();
      final accountId = await signUp('alice', 'hunter2', identityA);

      final path = '/$accountId/devices/${identityA.nodeId}';
      final headers = await signedHeaders(
        identityA,
        method: 'DELETE',
        path: path,
      );
      final response = await http.delete(
        Uri.parse('$baseUrl$path'),
        headers: headers,
      );

      expect(response.statusCode, 204);
    });

    test(
      'an unrelated account cannot unlink another account\'s device (403)',
      () async {
        final identityA = await newIdentity();
        final accountIdAlice = await signUp('alice', 'hunter2', identityA);

        final identityC = await newIdentity();
        await signUp('carol', 'hunter3', identityC);

        final path = '/$accountIdAlice/devices/${identityA.nodeId}';
        final headers = await signedHeaders(
          identityC,
          method: 'DELETE',
          path: path,
        );
        final response = await http.delete(
          Uri.parse('$baseUrl$path'),
          headers: headers,
        );

        expect(response.statusCode, 403);
        final lookup = await http.get(
          Uri.parse('$baseUrl/by-device/${identityA.nodeId}'),
        );
        expect(lookup.statusCode, 200);
      },
    );

    test('an unauthenticated request is rejected with 401', () async {
      final identityA = await newIdentity();
      final accountId = await signUp('alice', 'hunter2', identityA);

      final response = await http.delete(
        Uri.parse('$baseUrl/$accountId/devices/${identityA.nodeId}'),
      );
      expect(response.statusCode, 401);
    });

    test('unlinking an already-unlinked nodeId is a no-op 204', () async {
      final identityA = await newIdentity();
      final accountId = await signUp('alice', 'hunter2', identityA);

      final path = '/$accountId/devices/never-linked';
      final headers = await signedHeaders(
        identityA,
        method: 'DELETE',
        path: path,
      );
      final response = await http.delete(
        Uri.parse('$baseUrl$path'),
        headers: headers,
      );
      expect(response.statusCode, 204);
    });
  });

  group('friend requests', () {
    test('send -> appears in the recipient pending list -> accept -> devices '
        'endpoint now works for either side against the other, still 403s '
        'for an unrelated third account', () async {
      final aliceIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'pw-alice', aliceIdentity);
      final bobIdentity = await newIdentity();
      final bobId = await signUp('bob', 'pw-bob', bobIdentity);
      final carolIdentity = await newIdentity();
      await signUp('carol', 'pw-carol', carolIdentity);

      // Before any friend request: devices are not visible to bob.
      final beforePath = '/$aliceId/devices';
      final beforeHeaders = await signedHeaders(
        bobIdentity,
        method: 'GET',
        path: beforePath,
      );
      final before = await http.get(
        Uri.parse('$baseUrl$beforePath'),
        headers: beforeHeaders,
      );
      expect(before.statusCode, 403);

      // alice sends bob a friend request.
      final sendPath = '/$aliceId/friend-requests';
      final sendBody = jsonEncode({'toUsername': 'bob'});
      final sendHeaders = await signedHeaders(
        aliceIdentity,
        method: 'POST',
        path: sendPath,
        body: sendBody,
      );
      final sendResponse = await http.post(
        Uri.parse('$baseUrl$sendPath'),
        headers: sendHeaders,
        body: sendBody,
      );
      expect(sendResponse.statusCode, 201);
      final requestId =
          (jsonDecode(sendResponse.body) as Map<String, dynamic>)['id']
              as String;

      // it shows up in bob's pending list.
      final listPath = '/$bobId/friend-requests';
      final listHeaders = await signedHeaders(
        bobIdentity,
        method: 'GET',
        path: listPath,
      );
      final listResponse = await http.get(
        Uri.parse('$baseUrl$listPath?status=pending'),
        headers: listHeaders,
      );
      expect(listResponse.statusCode, 200);
      final pending = jsonDecode(listResponse.body) as List<dynamic>;
      expect(pending, hasLength(1));
      expect((pending.single as Map<String, dynamic>)['id'], requestId);

      // bob accepts.
      final acceptPath = '/$bobId/friend-requests/$requestId/accept';
      final acceptHeaders = await signedHeaders(
        bobIdentity,
        method: 'POST',
        path: acceptPath,
      );
      final acceptResponse = await http.post(
        Uri.parse('$baseUrl$acceptPath'),
        headers: acceptHeaders,
      );
      expect(acceptResponse.statusCode, 200);
      expect(
        (jsonDecode(acceptResponse.body) as Map<String, dynamic>)['status'],
        'accepted',
      );

      // now both directions can see each other's devices.
      final afterHeaders = await signedHeaders(
        bobIdentity,
        method: 'GET',
        path: beforePath,
      );
      final after = await http.get(
        Uri.parse('$baseUrl$beforePath'),
        headers: afterHeaders,
      );
      expect(after.statusCode, 200);

      final reversePath = '/$bobId/devices';
      final reverseHeaders = await signedHeaders(
        aliceIdentity,
        method: 'GET',
        path: reversePath,
      );
      final reverse = await http.get(
        Uri.parse('$baseUrl$reversePath'),
        headers: reverseHeaders,
      );
      expect(reverse.statusCode, 200);

      // an unrelated third account still gets 403.
      final carolHeaders = await signedHeaders(
        carolIdentity,
        method: 'GET',
        path: beforePath,
      );
      final carolAttempt = await http.get(
        Uri.parse('$baseUrl$beforePath'),
        headers: carolHeaders,
      );
      expect(carolAttempt.statusCode, 403);
    });

    test('declining leaves both sides definitely not mutual friends -- the '
        'devices gate still 403s', () async {
      final aliceIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'pw-alice', aliceIdentity);
      final bobIdentity = await newIdentity();
      final bobId = await signUp('bob', 'pw-bob', bobIdentity);

      final sendPath = '/$aliceId/friend-requests';
      final sendBody = jsonEncode({'toUsername': 'bob'});
      final sendHeaders = await signedHeaders(
        aliceIdentity,
        method: 'POST',
        path: sendPath,
        body: sendBody,
      );
      final sendResponse = await http.post(
        Uri.parse('$baseUrl$sendPath'),
        headers: sendHeaders,
        body: sendBody,
      );
      final requestId =
          (jsonDecode(sendResponse.body) as Map<String, dynamic>)['id']
              as String;

      final declinePath = '/$bobId/friend-requests/$requestId/decline';
      final declineHeaders = await signedHeaders(
        bobIdentity,
        method: 'POST',
        path: declinePath,
      );
      final declineResponse = await http.post(
        Uri.parse('$baseUrl$declinePath'),
        headers: declineHeaders,
      );
      expect(declineResponse.statusCode, 200);
      expect(
        (jsonDecode(declineResponse.body) as Map<String, dynamic>)['status'],
        'declined',
      );

      final devicesPath = '/$aliceId/devices';
      final devicesHeaders = await signedHeaders(
        bobIdentity,
        method: 'GET',
        path: devicesPath,
      );
      final devicesResponse = await http.get(
        Uri.parse('$baseUrl$devicesPath'),
        headers: devicesHeaders,
      );
      expect(devicesResponse.statusCode, 403);
    });

    test('cannot send a friend request to yourself', () async {
      final aliceIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'pw-alice', aliceIdentity);

      final path = '/$aliceId/friend-requests';
      final body = jsonEncode({'toUsername': 'alice'});
      final headers = await signedHeaders(
        aliceIdentity,
        method: 'POST',
        path: path,
        body: body,
      );
      final response = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: headers,
        body: body,
      );
      expect(response.statusCode, 400);
    });

    test('cannot send a friend request to an unknown username', () async {
      final aliceIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'pw-alice', aliceIdentity);

      final path = '/$aliceId/friend-requests';
      final body = jsonEncode({'toUsername': 'does-not-exist'});
      final headers = await signedHeaders(
        aliceIdentity,
        method: 'POST',
        path: path,
        body: body,
      );
      final response = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: headers,
        body: body,
      );
      expect(response.statusCode, 404);
    });

    test('cannot act as another account\'s <me>', () async {
      final aliceIdentity = await newIdentity();
      await signUp('alice', 'pw-alice', aliceIdentity);
      final bobIdentity = await newIdentity();
      final bobId = await signUp('bob', 'pw-bob', bobIdentity);

      // alice authenticates herself but claims to be acting as bob.
      final path = '/$bobId/friend-requests';
      final body = jsonEncode({'toUsername': 'bob'});
      final headers = await signedHeaders(
        aliceIdentity,
        method: 'POST',
        path: path,
        body: body,
      );
      final response = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: headers,
        body: body,
      );
      expect(response.statusCode, 403);
    });
  });

  group('GET /<accountId>/devices', () {
    test('an account can always see its own device list', () async {
      final identity = await newIdentity();
      final accountId = await signUp('alice', 'hunter2', identity);

      final path = '/$accountId/devices';
      final headers = await signedHeaders(identity, method: 'GET', path: path);
      final response = await http.get(
        Uri.parse('$baseUrl$path'),
        headers: headers,
      );

      expect(response.statusCode, 200);
    });

    test('404s an accountId that does not exist', () async {
      final identity = await newIdentity();
      await signUp('alice', 'hunter2', identity);

      final path = '/does-not-exist/devices';
      final headers = await signedHeaders(identity, method: 'GET', path: path);
      final response = await http.get(
        Uri.parse('$baseUrl$path'),
        headers: headers,
      );

      expect(response.statusCode, 404);
    });

    test('401s an unauthenticated request', () async {
      final identity = await newIdentity();
      final accountId = await signUp('alice', 'hunter2', identity);

      final response = await http.get(Uri.parse('$baseUrl/$accountId/devices'));
      expect(response.statusCode, 401);
    });
  });

  group('GET /<me>/friends', () {
    /// Sends a friend request from [from] to [toUsername] and returns its id.
    Future<String> sendFriendRequest(
      NodeIdentity from,
      String fromAccountId,
      String toUsername,
    ) async {
      final path = '/$fromAccountId/friend-requests';
      final body = jsonEncode({'toUsername': toUsername});
      final response = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(
          from,
          method: 'POST',
          path: path,
          body: body,
        ),
        body: body,
      );
      expect(response.statusCode, 201);
      return (jsonDecode(response.body) as Map<String, dynamic>)['id']
          as String;
    }

    Future<void> respond(
      NodeIdentity recipient,
      String recipientAccountId,
      String requestId,
      String action,
    ) async {
      final path = '/$recipientAccountId/friend-requests/$requestId/$action';
      final response = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(recipient, method: 'POST', path: path),
      );
      expect(response.statusCode, 200);
    }

    Future<http.Response> listFriends(
      NodeIdentity identity,
      String accountId,
    ) async {
      final path = '/$accountId/friends';
      return http.get(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(identity, method: 'GET', path: path),
      );
    }

    test('lists an accepted friendship from *both* ends, not just the '
        'recipient\'s -- the gap listAddressedTo alone leaves', () async {
      final aliceIdentity = await newIdentity();
      final bobIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'hunter2', aliceIdentity);
      final bobId = await signUp('bob', 'hunter2', bobIdentity);

      final requestId = await sendFriendRequest(aliceIdentity, aliceId, 'bob');
      await respond(bobIdentity, bobId, requestId, 'accept');

      // Bob, the recipient: the direction `listAddressedTo` already covered.
      final bobsFriends =
          jsonDecode((await listFriends(bobIdentity, bobId)).body)
              as List<dynamic>;
      expect(bobsFriends, hasLength(1));
      expect(
        (bobsFriends.single as Map<String, dynamic>)['accountId'],
        aliceId,
      );
      expect((bobsFriends.single as Map<String, dynamic>)['username'], 'alice');

      // Alice, the *sender*: the direction that was previously invisible.
      final alicesFriends =
          jsonDecode((await listFriends(aliceIdentity, aliceId)).body)
              as List<dynamic>;
      expect(alicesFriends, hasLength(1));
      expect(
        (alicesFriends.single as Map<String, dynamic>)['accountId'],
        bobId,
      );
      expect((alicesFriends.single as Map<String, dynamic>)['username'], 'bob');
    });

    test('inlines each friend\'s full device list, matching what GET '
        '/<accountId>/devices would disclose to the same caller', () async {
      final aliceIdentity = await newIdentity();
      final aliceSecondDevice = await newIdentity();
      final bobIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'hunter2', aliceIdentity);
      final bobId = await signUp('bob', 'hunter2', bobIdentity);
      // Alice logs in on a second device, so her list is worth inlining.
      expect(
        (await completeLogin(
          username: 'alice',
          password: 'hunter2',
          identity: aliceSecondDevice,
        )).statusCode,
        200,
      );

      final requestId = await sendFriendRequest(aliceIdentity, aliceId, 'bob');
      await respond(bobIdentity, bobId, requestId, 'accept');

      final inlined =
          ((jsonDecode((await listFriends(bobIdentity, bobId)).body)
                      as List<dynamic>)
                  .single
              as Map<String, dynamic>)['devices'];

      // The equivalence this route's design relies on: the same caller can
      // already fetch exactly this, one signed round trip at a time.
      final devicesPath = '/$aliceId/devices';
      final viaDevicesRoute = await http.get(
        Uri.parse('$baseUrl$devicesPath'),
        headers: await signedHeaders(
          bobIdentity,
          method: 'GET',
          path: devicesPath,
        ),
      );
      expect(viaDevicesRoute.statusCode, 200);
      expect(
        inlined,
        (jsonDecode(viaDevicesRoute.body) as Map<String, dynamic>)['devices'],
      );
      expect(inlined, hasLength(2));
    });

    test('never leaks a password hash, even though it reports whole '
        'accounts', () async {
      final aliceIdentity = await newIdentity();
      final bobIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'hunter2', aliceIdentity);
      final bobId = await signUp('bob', 'hunter2', bobIdentity);
      final requestId = await sendFriendRequest(aliceIdentity, aliceId, 'bob');
      await respond(bobIdentity, bobId, requestId, 'accept');

      final body = (await listFriends(bobIdentity, bobId)).body;

      expect(body.toLowerCase(), isNot(contains('password')));
      expect(body.toLowerCase(), isNot(contains('argon')));
      expect(
        ((jsonDecode(body) as List<dynamic>).single as Map<String, dynamic>)
            .keys
            .toSet(),
        {'accountId', 'username', 'devices'},
      );
    });

    test('omits pending and declined requests', () async {
      final aliceIdentity = await newIdentity();
      final bobIdentity = await newIdentity();
      final carolIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'hunter2', aliceIdentity);
      final bobId = await signUp('bob', 'hunter2', bobIdentity);
      await signUp('carol', 'hunter2', carolIdentity);

      // Pending: never accepted.
      await sendFriendRequest(aliceIdentity, aliceId, 'carol');
      // Declined.
      final declined = await sendFriendRequest(aliceIdentity, aliceId, 'bob');
      await respond(bobIdentity, bobId, declined, 'decline');

      final friends =
          jsonDecode((await listFriends(aliceIdentity, aliceId)).body)
              as List<dynamic>;
      expect(friends, isEmpty);
    });

    test(
      'counts a pair that accepted in both directions once, not twice',
      () async {
        final aliceIdentity = await newIdentity();
        final bobIdentity = await newIdentity();
        final aliceId = await signUp('alice', 'hunter2', aliceIdentity);
        final bobId = await signUp('bob', 'hunter2', bobIdentity);

        final aliceToBob = await sendFriendRequest(
          aliceIdentity,
          aliceId,
          'bob',
        );
        await respond(bobIdentity, bobId, aliceToBob, 'accept');
        final bobToAlice = await sendFriendRequest(bobIdentity, bobId, 'alice');
        await respond(aliceIdentity, aliceId, bobToAlice, 'accept');

        final friends =
            jsonDecode((await listFriends(aliceIdentity, aliceId)).body)
                as List<dynamic>;
        expect(friends, hasLength(1));
        expect((friends.single as Map<String, dynamic>)['accountId'], bobId);
      },
    );

    test('401s an unauthenticated caller and 403s one acting as another '
        'account', () async {
      final aliceIdentity = await newIdentity();
      final bobIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'hunter2', aliceIdentity);
      await signUp('bob', 'hunter2', bobIdentity);

      expect(
        (await http.get(Uri.parse('$baseUrl/$aliceId/friends'))).statusCode,
        401,
      );
      expect((await listFriends(bobIdentity, aliceId)).statusCode, 403);
    });

    test(
      'is reachable on the *real mounted* server, not just this router -- '
      'the route-ordering trap /<me>/friend-requests could have hidden',
      () async {
        // Mounted exactly the way bin/relay.dart mounts it. A router tested in
        // isolation cannot catch a prefix being swallowed by a sibling mount
        // or a same-shape pattern registered earlier, which is the class of
        // mistake this codebase has already hit twice.
        final mountedRouter = Router()
          ..mount(
            '/accounts/',
            buildAccountRouter(accountStore, friendRequestStore).call,
          );
        final mounted = await shelf_io.serve(
          mountedRouter.call,
          'localhost',
          0,
        );
        addTearDown(() => mounted.close(force: true));
        final mountedUrl = 'http://localhost:${mounted.port}';

        final aliceIdentity = await newIdentity();
        final bobIdentity = await newIdentity();
        final aliceId = await signUp('alice', 'hunter2', aliceIdentity);
        final bobId = await signUp('bob', 'hunter2', bobIdentity);
        final requestId = await sendFriendRequest(
          aliceIdentity,
          aliceId,
          'bob',
        );
        await respond(bobIdentity, bobId, requestId, 'accept');

        final path = '/accounts/$bobId/friends';
        final response = await http.get(
          Uri.parse('$mountedUrl$path'),
          headers: await signedHeaders(bobIdentity, method: 'GET', path: path),
        );

        expect(response.statusCode, 200);
        expect(
          ((jsonDecode(response.body) as List<dynamic>).single
              as Map<String, dynamic>)['accountId'],
          aliceId,
        );

        // ...and the sibling it might have shadowed (or been shadowed by)
        // still resolves to its own handler through the same mount.
        final requestsPath = '/accounts/$bobId/friend-requests';
        final requests = await http.get(
          Uri.parse('$mountedUrl$requestsPath'),
          headers: await signedHeaders(
            bobIdentity,
            method: 'GET',
            path: requestsPath,
          ),
        );
        expect(requests.statusCode, 200);
        expect(
          ((jsonDecode(requests.body) as List<dynamic>).single
              as Map<String, dynamic>)['status'],
          'accepted',
        );
      },
    );
  });
}
