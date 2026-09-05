import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/device_notifier.dart';
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
  late _RecordingNotifier notifier;
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

    // Always present, so the push side is exercised by every friend-request
    // test in this file rather than only the group that asserts on it -- a
    // notifier that throws or blocks would then show up as a failure
    // wherever it happened, not just where it was expected.
    notifier = _RecordingNotifier();
    final router = buildAccountRouter(
      accountStore,
      friendRequestStore,
      loginNonceStore: LoginNonceStore(),
      loginRateLimiter: rateLimiter,
      deviceNotifier: notifier,
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

  /// Runs the full send + accept handshake so the two accounts are mutual
  /// friends -- the state `GET /<me>/friends` and `GET /<id>/devices` are
  /// both gated on.
  Future<void> befriend({
    required NodeIdentity fromIdentity,
    required String fromId,
    required String toUsername,
    required NodeIdentity toIdentity,
    required String toId,
  }) async {
    final sendPath = '/$fromId/friend-requests';
    final sendBody = jsonEncode({'toUsername': toUsername});
    final sent = await http.post(
      Uri.parse('$baseUrl$sendPath'),
      headers: await RequestSigner(
        fromIdentity,
      ).sign(method: 'POST', path: sendPath, body: sendBody),
      body: sendBody,
    );
    expect(sent.statusCode, 201);
    final requestId =
        (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;

    final acceptPath = '/$toId/friend-requests/$requestId/accept';
    final accepted = await http.post(
      Uri.parse('$baseUrl$acceptPath'),
      headers: await RequestSigner(
        toIdentity,
      ).sign(method: 'POST', path: acceptPath),
    );
    expect(accepted.statusCode, 200);
  }

  /// Pushes are deliberately fire-and-forget (`unawaited`, see
  /// `_notifyAccountDevices`), so they are *not* guaranteed to have happened
  /// by the time the HTTP response arrives -- that is the property being
  /// tested, not a flake. Wait for them explicitly instead of sleeping a
  /// fixed amount.
  Future<void> settlePushes({int atLeast = 1}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (notifier.pushes.length < atLeast &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // One more turn, so a test asserting "exactly these" catches a stray
    // extra push that was already queued.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

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

  group('DELETE /<me>/friends/<accountId>', () {
    late NodeIdentity alicePhone;
    late NodeIdentity bobPhone;
    late String aliceId;
    late String bobId;

    setUp(() async {
      alicePhone = await newIdentity();
      bobPhone = await newIdentity();
      aliceId = await signUp('alice', 'hunter2', alicePhone);
      bobId = await signUp('bob', 'hunter2', bobPhone);
    });

    Future<http.Response> revoke(
      NodeIdentity as,
      String meId,
      String friendId,
    ) async {
      final path = '/$meId/friends/$friendId';
      return http.delete(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(as, method: 'DELETE', path: path),
      );
    }

    Future<List<dynamic>> friendsOf(NodeIdentity as, String meId) async {
      final path = '/$meId/friends';
      final response = await http.get(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(as, method: 'GET', path: path),
      );
      expect(response.statusCode, 200);
      return jsonDecode(response.body) as List<dynamic>;
    }

    Future<int> devicesStatus(NodeIdentity as, String targetAccountId) async {
      final path = '/$targetAccountId/devices';
      final response = await http.get(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(as, method: 'GET', path: path),
      );
      return response.statusCode;
    }

    Future<void> makeFriends() => befriend(
      fromIdentity: alicePhone,
      fromId: aliceId,
      toUsername: 'bob',
      toIdentity: bobPhone,
      toId: bobId,
    );

    test(
      'either side can end the friendship, and it ends for *both*',
      () async {
        await makeFriends();
        expect(await friendsOf(alicePhone, aliceId), hasLength(1));
        expect(await friendsOf(bobPhone, bobId), hasLength(1));

        // Bob revokes -- and Bob was the *recipient* of the original request,
        // so this is the direction a naive "only the sender may undo it"
        // implementation would refuse.
        final response = await revoke(bobPhone, bobId, aliceId);

        expect(response.statusCode, 204);
        expect(response.body, isEmpty);
        expect(
          await friendRequestStore.areMutualFriends(aliceId, bobId),
          isFalse,
        );
        expect(await friendsOf(alicePhone, aliceId), isEmpty);
        expect(await friendsOf(bobPhone, bobId), isEmpty);
      },
    );

    test('closes the device-list gate again, in both directions', () async {
      await makeFriends();
      expect(await devicesStatus(alicePhone, bobId), 200);
      expect(await devicesStatus(bobPhone, aliceId), 200);

      expect((await revoke(alicePhone, aliceId, bobId)).statusCode, 204);

      expect(
        await devicesStatus(alicePhone, bobId),
        403,
        reason: 'the revoking side can still read the other account\'s keys',
      );
      expect(
        await devicesStatus(bobPhone, aliceId),
        403,
        reason: 'the revoked side can still read the other account\'s keys',
      );
      // Each account can always still see its own.
      expect(await devicesStatus(alicePhone, aliceId), 200);
    });

    test('401s an unauthenticated caller', () async {
      await makeFriends();

      final response = await http.delete(
        Uri.parse('$baseUrl/$aliceId/friends/$bobId'),
      );

      expect(response.statusCode, 401);
      expect(await friendRequestStore.areMutualFriends(aliceId, bobId), isTrue);
    });

    test('403s a caller acting as another account -- nobody may revoke '
        "somebody else's friendships", () async {
      await makeFriends();
      final carolPhone = await newIdentity();
      await signUp('carol', 'hunter2', carolPhone);

      final response = await revoke(carolPhone, aliceId, bobId);

      expect(response.statusCode, 403);
      expect(await friendRequestStore.areMutualFriends(aliceId, bobId), isTrue);
    });

    test('is idempotent: revoking twice, or revoking a friendship that never '
        'existed, is the same 204', () async {
      await makeFriends();

      expect((await revoke(alicePhone, aliceId, bobId)).statusCode, 204);
      expect((await revoke(alicePhone, aliceId, bobId)).statusCode, 204);
      // Never friends at all, and an account that does not exist -- both
      // answer identically, so this route is no enumeration oracle either.
      expect(
        (await revoke(alicePhone, aliceId, 'no-such-account')).statusCode,
        204,
      );
    });

    test('re-friending afterwards works end to end', () async {
      await makeFriends();
      await revoke(alicePhone, aliceId, bobId);

      // An ordinary new request, in the opposite direction this time.
      await befriend(
        fromIdentity: bobPhone,
        fromId: bobId,
        toUsername: 'alice',
        toIdentity: alicePhone,
        toId: aliceId,
      );

      expect(await friendRequestStore.areMutualFriends(aliceId, bobId), isTrue);
      expect(await friendsOf(alicePhone, aliceId), hasLength(1));
      expect(await devicesStatus(bobPhone, aliceId), 200);
    });

    test('nudges every device of *both* accounts, so the other side finds '
        'out without waiting for its next poll', () async {
      await makeFriends();
      // Alice has a second device, which also has to be told.
      final aliceDesktop = await newIdentity();
      expect(
        (await completeLogin(
          username: 'alice',
          password: 'hunter2',
          identity: aliceDesktop,
        )).statusCode,
        200,
      );
      notifier.pushes.clear();

      expect((await revoke(alicePhone, aliceId, bobId)).statusCode, 204);
      await settlePushes(atLeast: 3);

      expect(notifier.pushes.map((p) => p.nodeId).toSet(), {
        alicePhone.nodeId,
        aliceDesktop.nodeId,
        bobPhone.nodeId,
      });
      expect(notifier.pushes.map((p) => p.event).toSet(), {
        AccountEvent.friendRequests,
      });
    });

    test('a no-op revocation nudges nobody -- this is not a way to make some '
        "other account's devices poll on demand", () async {
      await makeFriends();
      await revoke(alicePhone, aliceId, bobId);
      await settlePushes(atLeast: 2);
      notifier.pushes.clear();

      expect((await revoke(alicePhone, aliceId, bobId)).statusCode, 204);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(notifier.pushes, isEmpty);
    });

    test('a notifier that throws never turns a successful revocation into an '
        'error', () async {
      await makeFriends();
      notifier
        ..pushes.clear()
        ..throwOnNotify = true;

      final response = await revoke(alicePhone, aliceId, bobId);

      expect(response.statusCode, 204);
      expect(
        await friendRequestStore.areMutualFriends(aliceId, bobId),
        isFalse,
      );
    });

    test('is reachable on the *real mounted* server, and does not shadow (or '
        'get shadowed by) its same-shape siblings', () async {
      final mountedRouter = Router()
        ..mount(
          '/accounts/',
          buildAccountRouter(accountStore, friendRequestStore).call,
        );
      final mounted = await shelf_io.serve(mountedRouter.call, 'localhost', 0);
      addTearDown(() => mounted.close(force: true));
      final mountedUrl = 'http://localhost:${mounted.port}';
      await makeFriends();

      // The sibling that pins `devices` in the same middle position must
      // still resolve to its own handler...
      final devicesPath = '/accounts/$aliceId/devices/${alicePhone.nodeId}';
      expect(
        (await http.delete(
          Uri.parse('$mountedUrl$devicesPath'),
          headers: await signedHeaders(
            alicePhone,
            method: 'DELETE',
            path: devicesPath,
          ),
        )).statusCode,
        204,
      );
      expect(
        (await accountStore.findById(aliceId))!.devices,
        isEmpty,
        reason: 'DELETE /<id>/friends/<id> swallowed the device-unlink route',
      );

      // ...and the new route resolves to *its* handler through the mount.
      // Alice signs with the device she just unlinked, so a fresh one is
      // needed to prove the revocation itself, not the unlink.
      final aliceLaptop = await newIdentity();
      expect(
        (await completeLogin(
          username: 'alice',
          password: 'hunter2',
          identity: aliceLaptop,
        )).statusCode,
        200,
      );
      final path = '/accounts/$aliceId/friends/$bobId';
      final response = await http.delete(
        Uri.parse('$mountedUrl$path'),
        headers: await signedHeaders(aliceLaptop, method: 'DELETE', path: path),
      );

      expect(response.statusCode, 204);
      expect(
        await friendRequestStore.areMutualFriends(aliceId, bobId),
        isFalse,
      );
    });
  });

  group("a device's relayUrl -- the one piece of reachability this service "
      'records', () {
    test('login/complete records it, and both device-listing routes return '
        'it', () async {
      final aliceIdentity = await newIdentity();
      final nonce = await startLogin('alice');
      final signature = await Ed25519().sign(
        nonce,
        keyPair: aliceIdentity.keyPair,
      );
      final response = await http.post(
        Uri.parse('$baseUrl/login/complete'),
        body: jsonEncode({
          'username': 'alice',
          'password': 'pw-alice',
          'nodeId': aliceIdentity.nodeId,
          'publicKeyBase64': await aliceIdentity.publicKeyBase64(),
          'signatureOverNonce': base64Encode(signature.bytes),
          'relayUrl': 'ws://relay.example:8090/connect',
        }),
      );
      expect(response.statusCode, 201);
      final aliceId =
          (jsonDecode(response.body) as Map<String, dynamic>)['accountId']
              as String;
      expect(
        ((jsonDecode(response.body) as Map<String, dynamic>)['devices']
                as List<dynamic>)
            .single['relayUrl'],
        'ws://relay.example:8090/connect',
      );

      // Her own device list...
      final devicesPath = '/$aliceId/devices';
      final devices = await http.get(
        Uri.parse('$baseUrl$devicesPath'),
        headers: await signedHeaders(
          aliceIdentity,
          method: 'GET',
          path: devicesPath,
        ),
      );
      expect(
        ((jsonDecode(devices.body) as Map<String, dynamic>)['devices']
                as List<dynamic>)
            .single['relayUrl'],
        'ws://relay.example:8090/connect',
      );

      // ...and what a mutual friend sees, which is the disclosure that
      // actually matters and the one that makes this friendship usable.
      final bobIdentity = await newIdentity();
      final bobId = await signUp('bob', 'pw-bob', bobIdentity);
      await befriend(
        fromIdentity: aliceIdentity,
        fromId: aliceId,
        toUsername: 'bob',
        toIdentity: bobIdentity,
        toId: bobId,
      );

      final friendsPath = '/$bobId/friends';
      final friends = await http.get(
        Uri.parse('$baseUrl$friendsPath'),
        headers: await signedHeaders(
          bobIdentity,
          method: 'GET',
          path: friendsPath,
        ),
      );
      expect(friends.statusCode, 200);
      final alice =
          (jsonDecode(friends.body) as List<dynamic>).single
              as Map<String, dynamic>;
      expect(
        (alice['devices'] as List<dynamic>).single['relayUrl'],
        'ws://relay.example:8090/connect',
      );
    });

    test('an accounts.json written before this field existed still loads, '
        'and its devices simply have no relay', () async {
      final aliceIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'pw-alice', aliceIdentity);

      // Rewrite the file exactly as an older version wrote it: no `relayUrl`
      // key on the device rows at all.
      final file = File('${accountsDataDir.path}/accounts.json');
      final rows = jsonDecode(await file.readAsString()) as List<dynamic>;
      for (final row in rows) {
        for (final device
            in (row as Map<String, dynamic>)['devices'] as List<dynamic>) {
          (device as Map<String, dynamic>).remove('relayUrl');
        }
      }
      await file.writeAsString(jsonEncode(rows));
      expect(await file.readAsString(), isNot(contains('relayUrl')));

      final devicesPath = '/$aliceId/devices';
      final devices = await http.get(
        Uri.parse('$baseUrl$devicesPath'),
        headers: await signedHeaders(
          aliceIdentity,
          method: 'GET',
          path: devicesPath,
        ),
      );

      expect(devices.statusCode, 200);
      final device =
          ((jsonDecode(devices.body) as Map<String, dynamic>)['devices']
                      as List<dynamic>)
                  .single
              as Map<String, dynamic>;
      expect(device['nodeId'], aliceIdentity.nodeId);
      expect(device['relayUrl'], isNull);
    });

    test(
      'a non-string relayUrl is rejected, without creating an account',
      () async {
        final aliceIdentity = await newIdentity();
        final nonce = await startLogin('alice');
        final signature = await Ed25519().sign(
          nonce,
          keyPair: aliceIdentity.keyPair,
        );
        final response = await http.post(
          Uri.parse('$baseUrl/login/complete'),
          body: jsonEncode({
            'username': 'alice',
            'password': 'pw-alice',
            'nodeId': aliceIdentity.nodeId,
            'publicKeyBase64': await aliceIdentity.publicKeyBase64(),
            'signatureOverNonce': base64Encode(signature.bytes),
            'relayUrl': 42,
          }),
        );

        expect(response.statusCode, 400);
        expect(await accountStore.loadAll(), isEmpty);
      },
    );
  });

  group('friend requests carry usernames', () {
    test("every friend-request response names the other side, because an "
        'accountId is not something an app can show a human', () async {
      final aliceIdentity = await newIdentity();
      final aliceId = await signUp('alice', 'pw-alice', aliceIdentity);
      final bobIdentity = await newIdentity();
      final bobId = await signUp('bob', 'pw-bob', bobIdentity);

      final sendPath = '/$aliceId/friend-requests';
      final sendBody = jsonEncode({'toUsername': 'bob'});
      final sent = await http.post(
        Uri.parse('$baseUrl$sendPath'),
        headers: await signedHeaders(
          aliceIdentity,
          method: 'POST',
          path: sendPath,
          body: sendBody,
        ),
        body: sendBody,
      );
      expect(sent.statusCode, 201);
      final sentBody = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(sentBody['fromUsername'], 'alice');
      expect(sentBody['toUsername'], 'bob');

      final listPath = '/$bobId/friend-requests';
      final listed = await http.get(
        Uri.parse('$baseUrl$listPath?status=pending'),
        headers: await signedHeaders(
          bobIdentity,
          method: 'GET',
          path: listPath,
        ),
      );
      final pending =
          (jsonDecode(listed.body) as List<dynamic>).single
              as Map<String, dynamic>;
      expect(pending['fromUsername'], 'alice');
      expect(pending['fromAccountId'], aliceId);

      final acceptPath = '/$bobId/friend-requests/${sentBody['id']}/accept';
      final accepted = await http.post(
        Uri.parse('$baseUrl$acceptPath'),
        headers: await signedHeaders(
          bobIdentity,
          method: 'POST',
          path: acceptPath,
        ),
      );
      expect(
        (jsonDecode(accepted.body) as Map<String, dynamic>)['fromUsername'],
        'alice',
      );
    });
  });

  /// The push is a nudge and nothing else: these assert *who* is told, and
  /// `relay_hub_test.dart`/`relay_client_test.dart` assert *what* is sent
  /// (an opaque event kind, no payload).
  group('pushing over the relay tunnel', () {
    late NodeIdentity alicePhone;
    late NodeIdentity aliceDesktop;
    late NodeIdentity bobPhone;
    late String aliceId;
    late String bobId;

    setUp(() async {
      alicePhone = await newIdentity();
      aliceDesktop = await newIdentity();
      bobPhone = await newIdentity();
      aliceId = await signUp('alice', 'pw-alice', alicePhone);
      // Alice's second device, on the same account -- the multi-device case
      // this service exists for.
      await completeLogin(
        username: 'alice',
        password: 'pw-alice',
        identity: aliceDesktop,
      );
      bobId = await signUp('bob', 'pw-bob', bobPhone);
      notifier.pushes.clear();
    });

    Future<String> sendRequestFromAliceToBob() async {
      final path = '/$aliceId/friend-requests';
      final body = jsonEncode({'toUsername': 'bob'});
      final response = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(
          alicePhone,
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

    test('sending nudges the recipient, and only the recipient', () async {
      await sendRequestFromAliceToBob();
      await settlePushes();

      expect(notifier.pushes.map((p) => p.nodeId), [bobPhone.nodeId]);
      expect(notifier.pushes.single.event, AccountEvent.friendRequests);
    });

    test('accepting nudges every device of both accounts -- the sender is '
        'the one who would otherwise never find out', () async {
      final requestId = await sendRequestFromAliceToBob();
      notifier.pushes.clear();

      final path = '/$bobId/friend-requests/$requestId/accept';
      final accepted = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(bobPhone, method: 'POST', path: path),
      );
      expect(accepted.statusCode, 200);
      await settlePushes(atLeast: 3);

      expect(notifier.pushes.map((p) => p.nodeId).toSet(), {
        alicePhone.nodeId,
        aliceDesktop.nodeId,
        bobPhone.nodeId,
      });
    });

    test("declining nudges only the decliner's own devices -- the sender "
        'has nothing they could fetch, and is not told', () async {
      final requestId = await sendRequestFromAliceToBob();
      notifier.pushes.clear();

      final path = '/$bobId/friend-requests/$requestId/decline';
      final declined = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(bobPhone, method: 'POST', path: path),
      );
      expect(declined.statusCode, 200);
      await settlePushes();

      expect(notifier.pushes.map((p) => p.nodeId), [bobPhone.nodeId]);
    });

    test('a refused action nudges nobody', () async {
      final requestId = await sendRequestFromAliceToBob();
      notifier.pushes.clear();

      // Alice tries to accept her own outgoing request: 403, no state
      // change, so nothing to tell anyone about.
      final path = '/$aliceId/friend-requests/$requestId/accept';
      final refused = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(alicePhone, method: 'POST', path: path),
      );
      expect(refused.statusCode, 403);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(notifier.pushes, isEmpty);
    });

    test('a notifier that throws never turns a successful accept into an '
        'error -- a push is best-effort by definition', () async {
      final requestId = await sendRequestFromAliceToBob();
      notifier
        ..pushes.clear()
        ..throwOnNotify = true;

      final path = '/$bobId/friend-requests/$requestId/accept';
      final accepted = await http.post(
        Uri.parse('$baseUrl$path'),
        headers: await signedHeaders(bobPhone, method: 'POST', path: path),
      );

      expect(accepted.statusCode, 200);
      expect(
        (jsonDecode(accepted.body) as Map<String, dynamic>)['status'],
        'accepted',
      );
      // And the friendship really did take effect, despite the failed push.
      expect(await friendRequestStore.areMutualFriends(aliceId, bobId), isTrue);
    });
  });
}

/// A [DeviceNotifier] that writes down what it was asked to push instead of
/// sending anything -- the account service must not need a relay, or any
/// network at all, for these routes to work.
class _RecordingNotifier implements DeviceNotifier {
  final List<({String nodeId, AccountEvent event})> pushes = [];

  /// Simulates the one thing a real notifier promises never to do, so the
  /// "best-effort" claim is tested rather than asserted.
  bool throwOnNotify = false;

  @override
  void notifyDevice(String nodeId, AccountEvent event) {
    pushes.add((nodeId: nodeId, event: event));
    if (throwOnNotify) throw StateError('the relay exploded');
  }
}
