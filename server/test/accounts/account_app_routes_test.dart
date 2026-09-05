import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_session_store.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/accounts/login_rate_limiter.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

/// This node's own app-facing `/api/v1/account/*` routes, exercised against
/// a real [startMusicatServer] (so the mount prefix, the trailing-slash rule
/// and [requireLocal] are all the production ones) talking to a real account
/// service over real HTTP.
void main() {
  late Directory accountsDir;
  late Directory nodeDir;
  late AccountStore accountStore;
  late FriendRequestStore friendRequestStore;
  late LoginRateLimiter rateLimiter;
  late HttpServer accountServer;
  late String accountServiceUrl;
  late List<String> accountServiceCalls;

  /// Flipped on by the one test that needs the account service to answer
  /// `POST /login/*` normally but fail `GET /<me>/friends` -- the only way to
  /// exercise "the login worked, its sync didn't" for real.
  late bool failTheFriendsRoute;
  MusicatServerHandle? node;

  final identityDirs = <Directory>[];

  Future<NodeIdentity> newIdentity(String label) async {
    final dir = Directory.systemTemp.createTempSync('musicat_aar_${label}_');
    identityDirs.add(dir);
    return NodeIdentityStore(dir).loadOrCreate();
  }

  String nodeUrl(String path) => 'http://localhost:${node!.port}$path';

  /// This machine's first non-loopback address, or `null` in a sandbox with
  /// none -- the only way to exercise [requireLocal]'s *rejection* path for
  /// real, rather than by faking a header.
  Future<String?> findLanAddress() async {
    for (final interface in await NetworkInterface.list()) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) return address.address;
      }
    }
    return null;
  }

  Future<http.Response> logIn({
    required String username,
    required String password,
  }) => http.post(
    Uri.parse(nodeUrl('/api/v1/account/login')),
    body: jsonEncode({'username': username, 'password': password}),
  );

  setUp(() async {
    accountsDir = Directory.systemTemp.createTempSync('musicat_aar_accounts_');
    nodeDir = Directory.systemTemp.createTempSync('musicat_aar_node_');
    accountStore = AccountStore(accountsDir);
    friendRequestStore = FriendRequestStore(accountsDir);
    // Short enough that the rate-limit test doesn't need a real lockout.
    rateLimiter = LoginRateLimiter(
      maxAttempts: 2,
      lockoutDuration: const Duration(seconds: 30),
    );
    accountServiceCalls = [];
    failTheFriendsRoute = false;

    final router = Router()
      ..mount(
        '/accounts/',
        buildAccountRouter(
          accountStore,
          friendRequestStore,
          loginRateLimiter: rateLimiter,
        ).call,
      );
    accountServer = await shelf_io.serve(
      (Request request) {
        accountServiceCalls.add(
          '${request.method} ${request.requestedUri.path}',
        );
        if (failTheFriendsRoute &&
            request.requestedUri.path.endsWith('/friends')) {
          return Response.internalServerError(body: '{"error":"boom"}');
        }
        return router.call(request);
      },
      'localhost',
      0,
    );
    accountServiceUrl = 'http://localhost:${accountServer.port}/accounts';
  });

  tearDown(() async {
    await node?.close();
    node = null;
    await accountServer.close(force: true);
    accountsDir.deleteSync(recursive: true);
    nodeDir.deleteSync(recursive: true);
    for (final dir in identityDirs) {
      dir.deleteSync(recursive: true);
    }
    identityDirs.clear();
  });

  Future<void> startNode({
    String? withAccountService,
    String? appApiKey,
  }) async {
    node = await startMusicatServer(
      dataDir: nodeDir,
      port: 0,
      accountServiceUrl: withAccountService,
      appApiKey: appApiKey,
      // Long enough that the scheduled device refresh can never fire during
      // a test and add traffic these assertions would then have to allow.
      friendDeviceRefreshInterval: const Duration(hours: 12),
    );
  }

  group('POST /api/v1/account/login', () {
    test('signs up a brand-new account, persists the session and reports '
        'created: true', () async {
      await startNode(withAccountService: accountServiceUrl);

      final response = await logIn(username: 'jorge', password: 'hunter2-ok');

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['username'], 'jorge');
      expect(body['created'], isTrue);
      expect(body['accountId'], isNotEmpty);
      // The response carries no credential, and neither does the session.
      expect(body.keys.toSet(), {'accountId', 'username', 'created'});
      expect(response.body, isNot(contains('hunter2-ok')));

      final session = await AccountSessionStore(nodeDir).load();
      expect(session!.accountId, body['accountId']);
      expect(session.username, 'jorge');
    });

    test('links this device to an existing account and reports '
        'created: false', () async {
      // The account already exists, signed up from the user's other device.
      final otherDevice = await newIdentity('other');
      final existingAccountId = await _signUpDirect(
        accountServiceUrl,
        'jorge',
        'hunter2-ok',
        otherDevice,
      );
      await startNode(withAccountService: accountServiceUrl);

      final response = await logIn(username: 'jorge', password: 'hunter2-ok');

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['created'], isFalse);
      expect(body['accountId'], existingAccountId);
      // Both devices are now live on the one account -- multi-device is the
      // point, not a migration.
      final account = await accountStore.findByUsername('jorge');
      expect(account!.devices, hasLength(2));
      expect(
        {for (final device in account.devices) device.nodeId},
        {otherDevice.nodeId, node!.identity.nodeId},
      );
    });

    test(
      '401s a wrong password, and leaves any existing session alone',
      () async {
        await startNode(withAccountService: accountServiceUrl);
        final first = await logIn(username: 'jorge', password: 'hunter2-ok');
        final accountId =
            (jsonDecode(first.body) as Map<String, dynamic>)['accountId'];

        final response = await logIn(username: 'jorge', password: 'wrong');

        expect(response.statusCode, 401);
        expect(
          (jsonDecode(response.body) as Map<String, dynamic>)['error'],
          'Incorrect password',
        );
        // A failed login must not log you out of the account you were in.
        expect(
          (await AccountSessionStore(nodeDir).load())!.accountId,
          accountId,
        );
      },
    );

    test('429s once the account service rate-limits the username', () async {
      await startNode(withAccountService: accountServiceUrl);
      await logIn(username: 'jorge', password: 'hunter2-ok');

      // maxAttempts: 2 above.
      expect((await logIn(username: 'jorge', password: 'no')).statusCode, 401);
      expect((await logIn(username: 'jorge', password: 'no')).statusCode, 401);

      final response = await logIn(username: 'jorge', password: 'hunter2-ok');
      expect(response.statusCode, 429);
      expect(
        (jsonDecode(response.body) as Map<String, dynamic>)['error'],
        contains('Too many failed attempts'),
      );
    });

    test('400s an invalid username, without creating anything', () async {
      await startNode(withAccountService: accountServiceUrl);

      final response = await logIn(username: 'no', password: 'hunter2-ok');

      expect(response.statusCode, 400);
      expect(await accountStore.loadAll(), isEmpty);
      expect(await AccountSessionStore(nodeDir).load(), isNull);
    });

    test('503s when the account service is unreachable', () async {
      await startNode(withAccountService: accountServiceUrl);
      await accountServer.close(force: true);

      final response = await logIn(
        username: 'jorge',
        password: 'hunter2-ok',
      ).timeout(const Duration(seconds: 20));

      expect(response.statusCode, 503);
      expect(await AccountSessionStore(nodeDir).load(), isNull);
    });

    test('503s when this node has no account service configured at all -- '
        'the default, and not an error state', () async {
      await startNode();

      final response = await logIn(username: 'jorge', password: 'hunter2-ok');

      expect(response.statusCode, 503);
      expect(
        (jsonDecode(response.body) as Map<String, dynamic>)['error'],
        'No account service is configured for this node',
      );
    });

    test('400s a request missing username or password', () async {
      await startNode(withAccountService: accountServiceUrl);

      expect(
        (await http.post(
          Uri.parse(nodeUrl('/api/v1/account/login')),
          body: jsonEncode({'username': 'jorge'}),
        )).statusCode,
        400,
      );
      expect(
        (await http.post(
          Uri.parse(nodeUrl('/api/v1/account/login')),
          body: 'not json',
        )).statusCode,
        400,
      );
    });

    test('a successful login has already synced the account friends by the '
        'time it answers', () async {
      await startNode(withAccountService: accountServiceUrl);
      // Alice exists and has already accepted a request from this node's
      // account, which this node knows nothing about locally yet.
      final aliceDevice = await newIdentity('alice');
      final aliceAccountId = await _signUpDirect(
        accountServiceUrl,
        'alice',
        'hunter2-ok',
        aliceDevice,
      );
      final signup = await logIn(username: 'jorge', password: 'hunter2-ok');
      final myAccountId =
          (jsonDecode(signup.body) as Map<String, dynamic>)['accountId']
              as String;
      await _befriend(
        accountServiceUrl: accountServiceUrl,
        fromDevice: node!.identity,
        fromAccountId: myAccountId,
        toUsername: 'alice',
        toDevice: aliceDevice,
        toAccountId: aliceAccountId,
      );

      // Logging in again (this device is already linked, so this is the
      // "linked" branch) must run the sync before answering.
      final second = await logIn(username: 'jorge', password: 'hunter2-ok');
      expect(second.statusCode, 200);

      final friends =
          jsonDecode(
                (await http.get(
                  Uri.parse(nodeUrl('/api/v1/federation/friends')),
                )).body,
              )
              as List<dynamic>;
      expect(
        friends.map((f) => (f as Map<String, dynamic>)['accountId']),
        [aliceAccountId],
        reason:
            'the login answered before its friend sync had landed, so the '
            'app would see an empty friend list right after logging in',
      );
    });

    test('a failed friend sync never fails the login', () async {
      await startNode(withAccountService: accountServiceUrl);
      // The account service answers the login fine but breaks on the friend
      // list. The session is already persisted at that point, and the next
      // sync will retry, so this must not turn a successful login into a
      // failure the user has to react to.
      failTheFriendsRoute = true;

      final response = await logIn(username: 'jorge', password: 'hunter2-ok');

      expect(response.statusCode, 200);
      expect(
        accountServiceCalls.any((call) => call.endsWith('/friends')),
        isTrue,
        reason: 'the login did not attempt a sync at all',
      );
      expect(await AccountSessionStore(nodeDir).load(), isNotNull);
      expect(await FriendStore(nodeDir).loadAll(), isEmpty);
    });
  });

  group('GET /api/v1/account', () {
    test('reports null for a node that has never logged in', () async {
      await startNode(withAccountService: accountServiceUrl);

      final response = await http.get(Uri.parse(nodeUrl('/api/v1/account')));

      expect(response.statusCode, 200);
      expect(jsonDecode(response.body), {'account': null});
    });

    test('reports the current session, from local disk, with the account '
        'service unreachable', () async {
      await startNode(withAccountService: accountServiceUrl);
      final login = await logIn(username: 'jorge', password: 'hunter2-ok');
      final accountId =
          (jsonDecode(login.body) as Map<String, dynamic>)['accountId'];
      await accountServer.close(force: true);
      accountServiceCalls.clear();

      final response = await http
          .get(Uri.parse(nodeUrl('/api/v1/account')))
          .timeout(const Duration(seconds: 5));

      expect(response.statusCode, 200);
      final account =
          (jsonDecode(response.body) as Map<String, dynamic>)['account']
              as Map<String, dynamic>;
      expect(account['accountId'], accountId);
      expect(account['username'], 'jorge');
      expect(account['loggedInAt'], isNotEmpty);
      expect(account.keys.toSet(), {'accountId', 'username', 'loggedInAt'});
      // Rule 1: reading who you are is local disk and nothing else.
      expect(accountServiceCalls, isEmpty);
    });

    test('still answers on a node started without an account service '
        'configured, after a session was written by an earlier run', () async {
      await AccountSessionStore(
        nodeDir,
      ).save(accountId: 'acc-from-an-earlier-run', username: 'jorge');

      await startNode();

      final response = await http.get(Uri.parse(nodeUrl('/api/v1/account')));
      expect(response.statusCode, 200);
      expect(
        ((jsonDecode(response.body) as Map<String, dynamic>)['account']
            as Map<String, dynamic>)['accountId'],
        'acc-from-an-earlier-run',
      );
    });
  });

  group('DELETE /api/v1/account', () {
    test('clears the session, and is idempotent', () async {
      await startNode(withAccountService: accountServiceUrl);
      await logIn(username: 'jorge', password: 'hunter2-ok');

      expect(
        (await http.delete(Uri.parse(nodeUrl('/api/v1/account')))).statusCode,
        204,
      );
      expect(
        jsonDecode(
          (await http.get(Uri.parse(nodeUrl('/api/v1/account')))).body,
        ),
        {'account': null},
      );
      expect(
        (await http.delete(Uri.parse(nodeUrl('/api/v1/account')))).statusCode,
        204,
      );
    });

    test('leaves every friend exactly where they were -- logging out is not '
        'unfriending', () async {
      await startNode(withAccountService: accountServiceUrl);
      final friendStore = FriendStore(nodeDir);
      final friendDevice = await newIdentity('friend');
      await friendStore.add(
        Friend(
          accountId: 'friend-account',
          devices: [
            FriendDevice(
              nodeId: friendDevice.nodeId,
              publicKeyBase64: await friendDevice.publicKeyBase64(),
              address: 'friend.example:8080',
            ),
          ],
          displayName: 'A friend',
          localNickname: 'my label',
        ),
      );
      await logIn(username: 'jorge', password: 'hunter2-ok');

      await http.delete(Uri.parse(nodeUrl('/api/v1/account')));

      final friends = await friendStore.loadAll();
      expect(friends, hasLength(1));
      expect(friends.single.accountId, 'friend-account');
      expect(friends.single.devices.single.address, 'friend.example:8080');
      expect(friends.single.localNickname, 'my label');
      // And nothing was tombstoned either -- a logout is not a removal.
      expect(await friendStore.loadTombstones(), isEmpty);
    });
  });

  group('friend requests', () {
    late NodeIdentity aliceDevice;
    late String aliceAccountId;
    late String myAccountId;

    /// Sets this node up logged in as `jorge`, with `alice` existing as a
    /// separate account on the same service.
    Future<void> withTwoAccounts() async {
      aliceDevice = await newIdentity('alice');
      aliceAccountId = await _signUpDirect(
        accountServiceUrl,
        'alice',
        'hunter2-ok',
        aliceDevice,
      );
      await startNode(withAccountService: accountServiceUrl);
      final login = await logIn(username: 'jorge', password: 'hunter2-ok');
      expect(login.statusCode, 200);
      myAccountId =
          (jsonDecode(login.body) as Map<String, dynamic>)['accountId']
              as String;
    }

    Future<http.Response> aliceSendsMeARequest() async {
      final path = '/accounts/$aliceAccountId/friend-requests';
      final body = jsonEncode({'toUsername': 'jorge'});
      final uri = Uri.parse(
        '${accountServiceUrl.replaceAll('/accounts', '')}$path',
      );
      final headers = await RequestSigner(
        aliceDevice,
      ).sign(method: 'POST', path: path, body: body);
      final response = await http.post(uri, headers: headers, body: body);
      expect(response.statusCode, 201);
      return response;
    }

    group('with no session', () {
      test('every route answers 409 -- a conflict with this node\'s state, '
          'not a missing credential from the caller', () async {
        await startNode(withAccountService: accountServiceUrl);

        final listed = await http.get(
          Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
        );
        expect(listed.statusCode, 409);
        expect(
          (jsonDecode(listed.body) as Map<String, dynamic>)['error'],
          contains('not logged in'),
        );

        final sent = await http.post(
          Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
          body: jsonEncode({'toUsername': 'alice'}),
        );
        expect(sent.statusCode, 409);

        final accepted = await http.post(
          Uri.parse(nodeUrl('/api/v1/account/friend-requests/abc/accept')),
        );
        expect(accepted.statusCode, 409);

        final declined = await http.post(
          Uri.parse(nodeUrl('/api/v1/account/friend-requests/abc/decline')),
        );
        expect(declined.statusCode, 409);
      });
    });

    test('503s every route on a node with no account service configured, '
        'rather than crashing on a null', () async {
      await startNode();

      expect(
        (await http.get(
          Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
        )).statusCode,
        503,
      );
      expect(
        (await http.post(
          Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
          body: jsonEncode({'toUsername': 'alice'}),
        )).statusCode,
        503,
      );
      expect(
        (await http.post(
          Uri.parse(nodeUrl('/api/v1/account/friend-requests/abc/accept')),
        )).statusCode,
        503,
      );
    });

    test('sends one by username, and it really lands in the other account\'s '
        'pending list', () async {
      await withTwoAccounts();

      final response = await http.post(
        Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
        body: jsonEncode({'toUsername': 'alice'}),
      );

      expect(response.statusCode, 201);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['fromAccountId'], myAccountId);
      expect(body['fromUsername'], 'jorge');
      expect(body['toUsername'], 'alice');
      expect(body['status'], 'pending');

      final stored = await friendRequestStore.listAddressedTo(aliceAccountId);
      expect(stored.single.id, body['id']);
    });

    test('404s an unknown username, with the service\'s own wording', () async {
      await withTwoAccounts();

      final response = await http.post(
        Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
        body: jsonEncode({'toUsername': 'nobody-here'}),
      );

      expect(response.statusCode, 404);
      expect(
        (jsonDecode(response.body) as Map<String, dynamic>)['error'],
        'Unknown username',
      );
    });

    test('400s a missing toUsername before calling anything', () async {
      await withTwoAccounts();
      accountServiceCalls.clear();

      final response = await http.post(
        Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
        body: jsonEncode({}),
      );

      expect(response.statusCode, 400);
      expect(accountServiceCalls, isEmpty);
    });

    test('lists incoming pending requests with the sender\'s username, live '
        'from the account service', () async {
      await withTwoAccounts();
      final sent = await aliceSendsMeARequest();

      final response = await http.get(
        Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['live'], isTrue);
      expect(body['fetchedAt'], isNotEmpty);
      final requests = body['requests'] as List<dynamic>;
      expect(requests, hasLength(1));
      final request = requests.single as Map<String, dynamic>;
      expect(
        request['id'],
        (jsonDecode(sent.body) as Map<String, dynamic>)['id'],
      );
      // The whole reason this projection exists: a human-readable sender.
      expect(request['fromUsername'], 'alice');
      expect(request['fromAccountId'], aliceAccountId);
    });

    test('falls back to the last known list, marked not live, when the '
        'account service is unreachable', () async {
      await withTwoAccounts();
      await aliceSendsMeARequest();
      // One good fetch, so this node has something cached.
      expect(
        (await http.get(
          Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
        )).statusCode,
        200,
      );

      await accountServer.close(force: true);
      final response = await http
          .get(Uri.parse(nodeUrl('/api/v1/account/friend-requests')))
          .timeout(const Duration(seconds: 20));

      // A dead relay degrades to a slightly stale list, not a broken screen.
      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['live'], isFalse);
      expect(body['fetchedAt'], isNotEmpty);
      expect(
        ((body['requests'] as List<dynamic>).single
            as Map<String, dynamic>)['fromUsername'],
        'alice',
      );
    });

    test('reports fetchedAt: null when it has never managed a fetch -- an '
        'empty list this node cannot vouch for', () async {
      // A session restored from an earlier run: `POST /login` would have
      // fetched on its way past, and an empty list *with* a fetchedAt is a
      // real answer -- this is the genuinely-never-fetched state.
      await startNode(withAccountService: accountServiceUrl);
      await AccountSessionStore(
        nodeDir,
      ).save(accountId: 'acc-from-an-earlier-run', username: 'jorge');
      await accountServer.close(force: true);

      final response = await http
          .get(Uri.parse(nodeUrl('/api/v1/account/friend-requests')))
          .timeout(const Duration(seconds: 20));

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['live'], isFalse);
      // The distinction an app must not flatten: "nobody has asked to be
      // your friend" versus "this node has never been able to find out".
      expect(body['fetchedAt'], isNull);
      expect(body['requests'], isEmpty);
    });

    test('an empty list that really was fetched is reported as live, with a '
        'fetchedAt -- the other half of that distinction', () async {
      await withTwoAccounts();

      final body =
          jsonDecode(
                (await http.get(
                  Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
                )).body,
              )
              as Map<String, dynamic>;

      expect(body['requests'], isEmpty);
      expect(body['live'], isTrue);
      expect(body['fetchedAt'], isNotEmpty);
    });

    test('accepting makes the sender a real local friend before the call '
        'even returns', () async {
      await withTwoAccounts();
      final sent = await aliceSendsMeARequest();
      final requestId =
          (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;

      final response = await http.post(
        Uri.parse(nodeUrl('/api/v1/account/friend-requests/$requestId/accept')),
      );

      expect(response.statusCode, 200);
      expect(
        (jsonDecode(response.body) as Map<String, dynamic>)['status'],
        'accepted',
      );
      // The point of awaiting the refresh: no polling for the UI to do.
      final friends =
          jsonDecode(
                (await http.get(
                  Uri.parse(nodeUrl('/api/v1/federation/friends')),
                )).body,
              )
              as List<dynamic>;
      expect(friends, hasLength(1));
      expect(
        (friends.single as Map<String, dynamic>)['accountId'],
        aliceAccountId,
      );
      expect((friends.single as Map<String, dynamic>)['displayName'], 'alice');
    });

    test('accepting cannot resurrect an account this device deliberately '
        'removed -- Rule 2 has no exception here', () async {
      await withTwoAccounts();
      // The user unfriended Alice at some point. A tombstone says so.
      await FriendStore(nodeDir).remove(aliceAccountId);
      expect(await FriendStore(nodeDir).isRemoved(aliceAccountId), isTrue);

      final sent = await aliceSendsMeARequest();
      final requestId =
          (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;

      final response = await http.post(
        Uri.parse(nodeUrl('/api/v1/account/friend-requests/$requestId/accept')),
      );

      // The accept itself succeeds -- it is a fact about the *account*, and
      // this device does not get to veto it on the service.
      expect(response.statusCode, 200);
      // ...but this device still refuses to trust her locally, and only an
      // explicit local re-add can change that.
      expect(
        await FriendStore(nodeDir).findByAccountId(aliceAccountId),
        isNull,
      );
      expect(
        jsonDecode(
          (await http.get(
            Uri.parse(nodeUrl('/api/v1/federation/friends')),
          )).body,
        ),
        isEmpty,
      );
    });

    test(
      'declining answers the request and drops it from the cached list',
      () async {
        await withTwoAccounts();
        final sent = await aliceSendsMeARequest();
        final requestId =
            (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;

        final response = await http.post(
          Uri.parse(
            nodeUrl('/api/v1/account/friend-requests/$requestId/decline'),
          ),
        );

        expect(response.statusCode, 200);
        expect(
          (jsonDecode(response.body) as Map<String, dynamic>)['status'],
          'declined',
        );
        // No friend was created, and the pending list is empty again.
        expect(await FriendStore(nodeDir).loadAll(), isEmpty);
        final listed =
            jsonDecode(
                  (await http.get(
                    Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
                  )).body,
                )
                as Map<String, dynamic>;
        expect(listed['requests'], isEmpty);
      },
    );

    test('404s an unknown request id, and 409s one already answered', () async {
      await withTwoAccounts();
      final sent = await aliceSendsMeARequest();
      final requestId =
          (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;

      expect(
        (await http.post(
          Uri.parse(
            nodeUrl('/api/v1/account/friend-requests/no-such-id/accept'),
          ),
        )).statusCode,
        404,
      );

      expect(
        (await http.post(
          Uri.parse(
            nodeUrl('/api/v1/account/friend-requests/$requestId/accept'),
          ),
        )).statusCode,
        200,
      );
      final again = await http.post(
        Uri.parse(
          nodeUrl('/api/v1/account/friend-requests/$requestId/decline'),
        ),
      );
      expect(again.statusCode, 409);
    });

    test('logging out forgets the cached requests -- the next user of this '
        'node never sees the previous one\'s prompts', () async {
      await withTwoAccounts();
      await aliceSendsMeARequest();
      expect(
        ((jsonDecode(
                  (await http.get(
                    Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
                  )).body,
                )
                as Map<String, dynamic>)['requests']
            as List<dynamic>),
        hasLength(1),
      );

      expect(
        (await http.delete(Uri.parse(nodeUrl('/api/v1/account')))).statusCode,
        204,
      );
      await accountServer.close(force: true);

      // No session now, so this is a 409 -- but the point is that nothing
      // was left in memory for a later session to inherit.
      final listed = await http
          .get(Uri.parse(nodeUrl('/api/v1/account/friend-requests')))
          .timeout(const Duration(seconds: 5));
      expect(listed.statusCode, 409);
    });

    test('requireLocal covers all four of them, not just the routes that '
        'existed before', () async {
      await withTwoAccounts();
      final lanAddress = await findLanAddress();
      if (lanAddress == null) {
        markTestSkipped('No non-loopback network interface in this sandbox');
        return;
      }
      final base =
          'http://$lanAddress:${node!.port}/api/v1/account/friend-requests';
      accountServiceCalls.clear();

      expect(
        (await http.get(Uri.parse(base)).timeout(const Duration(seconds: 5)))
            .statusCode,
        403,
      );
      expect(
        (await http
                .post(
                  Uri.parse(base),
                  body: jsonEncode({'toUsername': 'alice'}),
                )
                .timeout(const Duration(seconds: 5)))
            .statusCode,
        403,
      );
      expect(
        (await http
                .post(Uri.parse('$base/x/accept'))
                .timeout(const Duration(seconds: 5)))
            .statusCode,
        403,
      );
      expect(
        (await http
                .post(Uri.parse('$base/x/decline'))
                .timeout(const Duration(seconds: 5)))
            .statusCode,
        403,
      );
      // The 403 came from requireLocal, not from anything downstream.
      expect(accountServiceCalls, isEmpty);
    });
  });

  group('requireLocal', () {
    test('a non-loopback caller gets 403 on every account route, including '
        'the one that takes a password', () async {
      await startNode(withAccountService: accountServiceUrl);
      final lanAddress = await findLanAddress();
      if (lanAddress == null) {
        markTestSkipped('No non-loopback network interface in this sandbox');
        return;
      }
      final base = 'http://$lanAddress:${node!.port}/api/v1/account';

      expect(
        (await http
                .post(
                  Uri.parse('$base/login'),
                  body: jsonEncode({
                    'username': 'jorge',
                    'password': 'hunter2-ok',
                  }),
                )
                .timeout(const Duration(seconds: 5)))
            .statusCode,
        403,
      );
      expect(
        (await http.get(Uri.parse(base)).timeout(const Duration(seconds: 5)))
            .statusCode,
        403,
      );
      expect(
        (await http.delete(Uri.parse(base)).timeout(const Duration(seconds: 5)))
            .statusCode,
        403,
      );
      // The 403 came from requireLocal, not from anything downstream: no
      // account was created and the service was never called.
      expect(await accountStore.loadAll(), isEmpty);
      expect(accountServiceCalls, isEmpty);
    });

    test('a non-loopback caller with the configured X-Api-Key is let '
        'through', () async {
      await startNode(
        withAccountService: accountServiceUrl,
        appApiKey: 'correct-key',
      );
      final lanAddress = await findLanAddress();
      if (lanAddress == null) {
        markTestSkipped('No non-loopback network interface in this sandbox');
        return;
      }

      final response = await http
          .get(
            Uri.parse('http://$lanAddress:${node!.port}/api/v1/account'),
            headers: {'X-Api-Key': 'correct-key'},
          )
          .timeout(const Duration(seconds: 5));

      expect(response.statusCode, 200);
    });
  });
}

/// Signs [identity] up directly against the account service, bypassing any
/// node -- used to stand up the *other* party in a friendship.
Future<String> _signUpDirect(
  String accountServiceUrl,
  String username,
  String password,
  NodeIdentity identity,
) async {
  final start = await http.post(
    Uri.parse('$accountServiceUrl/login/start'),
    body: jsonEncode({'username': username}),
  );
  final nonce = base64Decode(
    (jsonDecode(start.body) as Map<String, dynamic>)['nonceBase64'] as String,
  );
  final signature = await identity.sign(nonce);
  final response = await http.post(
    Uri.parse('$accountServiceUrl/login/complete'),
    body: jsonEncode({
      'username': username,
      'password': password,
      'nodeId': identity.nodeId,
      'publicKeyBase64': await identity.publicKeyBase64(),
      'signatureOverNonce': base64Encode(signature),
    }),
  );
  expect(response.statusCode, anyOf(200, 201));
  return (jsonDecode(response.body) as Map<String, dynamic>)['accountId']
      as String;
}

/// Sends and accepts a friend request directly against the account service.
Future<void> _befriend({
  required String accountServiceUrl,
  required NodeIdentity fromDevice,
  required String fromAccountId,
  required String toUsername,
  required NodeIdentity toDevice,
  required String toAccountId,
}) async {
  final origin = Uri.parse(accountServiceUrl);
  Future<http.Response> post(
    NodeIdentity identity,
    String path, {
    Object? body,
  }) async {
    final raw = body == null ? '' : jsonEncode(body);
    final uri = origin.replace(path: '${origin.path}$path');
    final headers = await RequestSigner(
      identity,
    ).sign(method: 'POST', path: uri.path, body: raw);
    return http.post(uri, headers: headers, body: raw);
  }

  final sent = await post(
    fromDevice,
    '/$fromAccountId/friend-requests',
    body: {'toUsername': toUsername},
  );
  expect(sent.statusCode, 201);
  final requestId =
      (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;
  final accepted = await post(
    toDevice,
    '/$toAccountId/friend-requests/$requestId/accept',
  );
  expect(accepted.statusCode, 200);
}
