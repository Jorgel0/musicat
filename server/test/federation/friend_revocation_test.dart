import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_service_client.dart';
import 'package:musicat_server/src/accounts/account_session_store.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/federation/friend_revocation.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

/// The durable half of bidirectional unfriending, against a **real** account
/// service (`shelf_io.serve` at the same `/accounts/` prefix `bin/relay.dart`
/// uses), with real Ed25519 identities, real Argon2id logins and real
/// accepted friend requests -- the same no-mocks standard
/// `account_friend_sync_test.dart` sets.
///
/// The properties worth protecting here are all about *not* being in the
/// way: the local removal already happened, so every failure mode in this
/// file has to be silent, bounded, and eventually self-correcting.
void main() {
  late Directory accountsDir;
  late Directory nodeDir;
  late AccountStore accountStore;
  late FriendRequestStore friendRequestStore;
  late HttpServer accountServer;
  late String accountServiceUrl;
  late List<String> accountServiceCalls;

  late AccountSessionStore sessionStore;
  late PendingRevocationStore queue;
  late AccountServiceClient accountService;
  late FriendRevocationService revocations;

  late NodeIdentity myDevice;
  late NodeIdentity alicePhone;
  late String myAccountId;
  late String aliceAccountId;

  final identityDirs = <Directory>[];

  Future<NodeIdentity> newIdentity(String label) async {
    final dir = Directory.systemTemp.createTempSync('musicat_rev_${label}_');
    identityDirs.add(dir);
    return NodeIdentityStore(dir).loadOrCreate();
  }

  Future<String> login(
    String username,
    String password,
    NodeIdentity identity,
  ) async {
    final start = await http.post(
      Uri.parse('$accountServiceUrl/accounts/login/start'),
      body: jsonEncode({'username': username}),
    );
    final nonce = base64Decode(
      (jsonDecode(start.body) as Map<String, dynamic>)['nonceBase64'] as String,
    );
    final signature = await Ed25519().sign(nonce, keyPair: identity.keyPair);
    final response = await http.post(
      Uri.parse('$accountServiceUrl/accounts/login/complete'),
      body: jsonEncode({
        'username': username,
        'password': password,
        'nodeId': identity.nodeId,
        'publicKeyBase64': await identity.publicKeyBase64(),
        'signatureOverNonce': base64Encode(signature.bytes),
      }),
    );
    expect(response.statusCode, anyOf(200, 201));
    return (jsonDecode(response.body) as Map<String, dynamic>)['accountId']
        as String;
  }

  Future<http.Response> signedRequest(
    NodeIdentity identity,
    String method,
    String path, {
    Object? body,
  }) async {
    final raw = body == null ? '' : jsonEncode(body);
    final headers = await RequestSigner(
      identity,
    ).sign(method: method, path: path, body: raw);
    final uri = Uri.parse('$accountServiceUrl$path');
    return switch (method) {
      'POST' => http.post(uri, headers: headers, body: raw),
      'DELETE' => http.delete(uri, headers: headers),
      _ => http.get(uri, headers: headers),
    };
  }

  /// Runs the full request/accept handshake so this node's account and
  /// Alice's are accepted friends on the account service.
  Future<void> befriendAlice() async {
    final sent = await signedRequest(
      myDevice,
      'POST',
      '/accounts/$myAccountId/friend-requests',
      body: {'toUsername': 'alice'},
    );
    expect(sent.statusCode, 201);
    final requestId =
        (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;
    final accepted = await signedRequest(
      alicePhone,
      'POST',
      '/accounts/$aliceAccountId/friend-requests/$requestId/accept',
    );
    expect(accepted.statusCode, 200);
  }

  setUp(() async {
    accountsDir = Directory.systemTemp.createTempSync('musicat_rev_accounts_');
    nodeDir = Directory.systemTemp.createTempSync('musicat_rev_node_');
    accountStore = AccountStore(accountsDir);
    friendRequestStore = FriendRequestStore(accountsDir);
    accountServiceCalls = [];

    final router = Router()
      ..mount(
        '/accounts/',
        buildAccountRouter(accountStore, friendRequestStore).call,
      );
    accountServer = await shelf_io.serve(
      (Request request) {
        accountServiceCalls.add(
          '${request.method} ${request.requestedUri.path}',
        );
        return router.call(request);
      },
      'localhost',
      0,
    );
    accountServiceUrl = 'http://localhost:${accountServer.port}';

    myDevice = await newIdentity('mine');
    alicePhone = await newIdentity('alice_phone');
    myAccountId = await login('jorge', 'hunter2-correct', myDevice);
    aliceAccountId = await login('alice', 'hunter2-correct', alicePhone);

    sessionStore = AccountSessionStore(nodeDir);
    queue = PendingRevocationStore(nodeDir);
    accountService = AccountServiceClient(
      baseUrl: '$accountServiceUrl/accounts',
      identity: myDevice,
      // Short, so the "the service is down" tests don't sit through the real
      // five seconds several times over.
      timeout: const Duration(milliseconds: 400),
    );
    revocations = FriendRevocationService(
      sessionStore: sessionStore,
      accountService: accountService,
      store: queue,
      // Tiny, so a retry is observable without waiting on wall-clock time --
      // the same reason `FriendDeviceRefresher.refreshInterval` is a
      // parameter.
      initialRetryDelay: const Duration(milliseconds: 20),
      maxRetryDelay: const Duration(milliseconds: 40),
    );

    accountServiceCalls.clear();
  });

  tearDown(() async {
    accountService.close();
    await accountServer.close(force: true);
    accountsDir.deleteSync(recursive: true);
    nodeDir.deleteSync(recursive: true);
    for (final dir in identityDirs) {
      dir.deleteSync(recursive: true);
    }
    identityDirs.clear();
  });

  Future<void> logIn() =>
      sessionStore.save(accountId: myAccountId, username: 'jorge');

  File queueFile() => File('${nodeDir.path}/pending_revocations.json');

  /// [FriendRevocationService.revoke] deliberately fires its delivery
  /// attempt `unawaited` -- that is the property under test, not a flake --
  /// and [FriendRevocationService.drain]'s overlap guard makes a `drain()`
  /// called right afterwards a no-op while that one is still in flight. So
  /// wait for the outcome rather than for a call.
  Future<void> settleUntil(bool Function(List<PendingRevocation>) done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done(await queue.loadAll()) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> settleDelivered() => settleUntil((owed) => owed.isEmpty);

  Future<void> settleFailedOnce() =>
      settleUntil((owed) => owed.length == 1 && owed.single.attempts >= 1);

  group('PendingRevocationStore', () {
    test(
      'persists across instances -- the whole reason it is a file',
      () async {
        await queue.enqueue(friendAccountId: 'friend-1', asAccountId: 'me');

        final reloaded = await PendingRevocationStore(nodeDir).loadAll();
        expect(reloaded, hasLength(1));
        expect(reloaded.single.friendAccountId, 'friend-1');
        expect(reloaded.single.asAccountId, 'me');
        expect(reloaded.single.attempts, 0);
      },
    );

    test(
      'enqueueing the same pair twice keeps one entry, with the backoff '
      'reset -- this is a set of facts, not a log of button presses',
      () async {
        await queue.enqueue(friendAccountId: 'friend-1', asAccountId: 'me');
        await queue.recordFailure(
          friendAccountId: 'friend-1',
          asAccountId: 'me',
          nextAttemptAt: DateTime.now().toUtc().add(const Duration(hours: 5)),
        );

        await queue.enqueue(friendAccountId: 'friend-1', asAccountId: 'me');

        final all = await queue.loadAll();
        expect(all, hasLength(1));
        expect(all.single.attempts, 0);
      },
    );

    test('recordFailure on an entry that is already gone does nothing -- a '
        'concurrent dequeue must never resurrect it', () async {
      await queue.enqueue(friendAccountId: 'friend-1', asAccountId: 'me');
      await queue.dequeue(friendAccountId: 'friend-1', asAccountId: 'me');

      await queue.recordFailure(
        friendAccountId: 'friend-1',
        asAccountId: 'me',
        nextAttemptAt: DateTime.now().toUtc(),
      );

      expect(await queue.loadAll(), isEmpty);
    });

    test(
      'a corrupt file reads as an empty queue rather than throwing',
      () async {
        queueFile().writeAsStringSync('{not json at all');

        expect(await queue.loadAll(), isEmpty);
      },
    );
  });

  group('with no session', () {
    test('revoke() queues nothing and calls nobody', () async {
      await revocations.revoke(aliceAccountId);

      expect(
        queueFile().existsSync(),
        isFalse,
        reason:
            'a node that is not logged in has no account friendships to '
            'revoke, and must not accumulate work it can never drain',
      );
      expect(accountServiceCalls, isEmpty);
    });

    test('drain() sends nothing, and keeps what is already owed', () async {
      // Queued while logged in, then logged out -- logging out is not
      // abandoning a revocation.
      await queue.enqueue(
        friendAccountId: aliceAccountId,
        asAccountId: myAccountId,
      );

      expect(await revocations.drain(), 0);

      expect(accountServiceCalls, isEmpty);
      expect(await queue.loadAll(), hasLength(1));
    });
  });

  group('delivery', () {
    test('a revocation reaches the account service and really ends the '
        'friendship, for both accounts', () async {
      await logIn();
      await befriendAlice();
      expect(
        await friendRequestStore.areMutualFriends(myAccountId, aliceAccountId),
        isTrue,
      );
      accountServiceCalls.clear();

      await revocations.revoke(aliceAccountId);
      await settleDelivered();

      expect(
        await friendRequestStore.areMutualFriends(myAccountId, aliceAccountId),
        isFalse,
      );
      expect(
        accountServiceCalls,
        contains('DELETE /accounts/$myAccountId/friends/$aliceAccountId'),
      );
      expect(
        await queue.loadAll(),
        isEmpty,
        reason: 'a delivered revocation must not stay queued forever',
      );
    });

    test('revoke() persists the intent before it returns, so a crash right '
        'after it still owes the revocation', () async {
      await logIn();
      await befriendAlice();
      // The service is unreachable, so nothing can have been delivered.
      await accountServer.close(force: true);

      await revocations.revoke(aliceAccountId);

      expect(queueFile().existsSync(), isTrue);
      final owed = await PendingRevocationStore(nodeDir).loadAll();
      expect(owed.single.friendAccountId, aliceAccountId);
      expect(owed.single.asAccountId, myAccountId);
    });

    test('a failed delivery is retried later rather than lost -- including '
        'across a restart', () async {
      await logIn();
      await befriendAlice();
      final port = accountServer.port;
      await accountServer.close(force: true);

      await revocations.revoke(aliceAccountId);
      await settleFailedOnce();
      final afterFailure = await queue.loadAll();
      expect(afterFailure, hasLength(1));
      expect(afterFailure.single.attempts, 1);

      // The account service comes back, and so does this node -- a brand-new
      // service object over the same data directory, which is what a restart
      // actually is.
      final router = Router()
        ..mount(
          '/accounts/',
          buildAccountRouter(accountStore, friendRequestStore).call,
        );
      accountServer = await shelf_io.serve(router.call, 'localhost', port);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final restarted = FriendRevocationService(
        sessionStore: AccountSessionStore(nodeDir),
        accountService: accountService,
        store: PendingRevocationStore(nodeDir),
      );
      expect(await restarted.drain(), 1);

      expect(
        await friendRequestStore.areMutualFriends(myAccountId, aliceAccountId),
        isFalse,
        reason: 'the revocation was lost when the first attempt failed',
      );
      expect(await queue.loadAll(), isEmpty);
    });

    test('backs off: an entry that has just failed is not retried on the very '
        'next drain', () async {
      await logIn();
      await befriendAlice();
      await accountServer.close(force: true);
      // Its own instance, with a backoff far longer than this test can run:
      // the shared one deliberately uses a 20ms delay so *other* tests can
      // observe a retry, which is exactly the wrong thing here.
      final patient = FriendRevocationService(
        sessionStore: sessionStore,
        accountService: accountService,
        store: queue,
        initialRetryDelay: const Duration(minutes: 10),
      );

      await patient.revoke(aliceAccountId);
      await settleFailedOnce();
      final firstFailure = (await queue.loadAll()).single;
      expect(firstFailure.attempts, 1);
      expect(
        firstFailure.nextAttemptAt.isAfter(DateTime.now().toUtc()),
        isTrue,
      );

      // Immediately again: still well inside the backoff window, so the
      // entry is not even looked at. Without this, a dead account service
      // would cost one full timeout per queued entry on every single poll,
      // forever.
      expect(await patient.drain(), 0);
      expect((await queue.loadAll()).single.attempts, 1);
    });

    test(
      'gives up on an entry older than maxAge, without sending it',
      () async {
        await logIn();
        await befriendAlice();
        // Queued long enough ago that it is past any reasonable hope.
        await queue.enqueue(
          friendAccountId: aliceAccountId,
          asAccountId: myAccountId,
          queuedAt: DateTime.now().toUtc().subtract(const Duration(days: 31)),
        );
        accountServiceCalls.clear();

        expect(await revocations.drain(), 1);

        expect(await queue.loadAll(), isEmpty);
        expect(
          accountServiceCalls,
          isEmpty,
          reason: 'an expired entry is dropped, not sent one last time',
        );
        // And nothing about the friendship changed -- expiry loses only the
        // propagation, which the local removal never depended on.
        expect(
          await friendRequestStore.areMutualFriends(
            myAccountId,
            aliceAccountId,
          ),
          isTrue,
        );
      },
    );

    test('drops an entry queued as an account this node is no longer logged '
        'in as', () async {
      await befriendAlice();
      await queue.enqueue(
        friendAccountId: 'somebody',
        asAccountId: aliceAccountId,
      );
      // This node is now Jorge, not Alice.
      await logIn();
      accountServiceCalls.clear();

      expect(await revocations.drain(), 1);

      expect(await queue.loadAll(), isEmpty);
      expect(
        accountServiceCalls,
        isEmpty,
        reason:
            "sending it as the current account would be a request about "
            "somebody else's friend list",
      );
    });

    test('drops an entry the account service definitively refuses, instead '
        'of retrying it for a month', () async {
      // A session naming an account this device is not linked to: the
      // service answers, and answers 403.
      await sessionStore.save(accountId: aliceAccountId, username: 'alice');
      await befriendAlice();
      accountServiceCalls.clear();

      await revocations.revoke(myAccountId);
      await settleDelivered();

      expect(accountServiceCalls, hasLength(greaterThanOrEqualTo(1)));
      expect(await queue.loadAll(), isEmpty);
      // ...and it really did not take effect, which is the point of it being
      // refused rather than retried.
      expect(
        await friendRequestStore.areMutualFriends(myAccountId, aliceAccountId),
        isTrue,
      );
    });

    test(
      'two concurrent drains do not send the same revocation twice',
      () async {
        await logIn();
        await befriendAlice();
        // Enqueued directly rather than via `revoke`, which would already
        // have a drain in flight and make "concurrent" mean something else.
        await queue.enqueue(
          friendAccountId: aliceAccountId,
          asAccountId: myAccountId,
        );
        accountServiceCalls.clear();

        await Future.wait([revocations.drain(), revocations.drain()]);

        expect(
          accountServiceCalls.where((call) => call.startsWith('DELETE')).length,
          lessThanOrEqualTo(1),
        );
        expect(await queue.loadAll(), isEmpty);
      },
    );
  });
}
