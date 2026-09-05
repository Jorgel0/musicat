import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_service_client.dart';
import 'package:musicat_server/src/accounts/account_session_store.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/accounts/pending_friend_request_cache.dart';
import 'package:musicat_server/src/federation/account_friend_sync.dart';
import 'package:musicat_server/src/federation/account_update_poller.dart';
import 'package:musicat_server/src/federation/friend_revocation.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

/// [AccountUpdatePoller] against a real, live account service, with real
/// Ed25519 identities, real Argon2id logins and real friend requests — the
/// same no-mocks standard as `account_friend_sync_test.dart` and
/// `account_friend_devices_test.dart`.
///
/// The load-bearing test here is the first one: **a node with no session
/// makes no account-service call at all, however long the poller runs.**
/// Everything else this class does is a convenience; that one is a promise.
void main() {
  late Directory accountsDir;
  late Directory nodeDir;
  late AccountStore accountStore;
  late FriendRequestStore friendRequestStore;
  late HttpServer accountServer;
  late String accountServiceUrl;
  late List<String> accountServiceCalls;

  late FriendStore friendStore;
  late AccountSessionStore sessionStore;
  late AccountServiceClient accountService;
  late PendingFriendRequestCache pendingRequests;
  late PendingRevocationStore revocationQueue;
  late AccountUpdatePoller poller;

  late NodeIdentity myDevice;
  late NodeIdentity alicePhone;
  late String myAccountId;
  late String aliceAccountId;

  final identityDirs = <Directory>[];

  Future<NodeIdentity> newIdentity(String label) async {
    final dir = Directory.systemTemp.createTempSync('musicat_aup_${label}_');
    identityDirs.add(dir);
    return NodeIdentityStore(dir).loadOrCreate();
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
      _ => http.get(uri, headers: headers),
    };
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

  /// Alice sends *me* a friend request, and leaves it pending — the state
  /// the pending-request half of a poll exists to discover.
  Future<String> alicePendingRequest() async {
    final sent = await signedRequest(
      alicePhone,
      'POST',
      '/accounts/$aliceAccountId/friend-requests',
      body: {'toUsername': 'jorge'},
    );
    expect(sent.statusCode, 201);
    return (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;
  }

  setUp(() async {
    accountsDir = Directory.systemTemp.createTempSync('musicat_aup_accounts_');
    nodeDir = Directory.systemTemp.createTempSync('musicat_aup_node_');
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
        accountServiceCalls.add(request.requestedUri.path);
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

    friendStore = FriendStore(nodeDir);
    sessionStore = AccountSessionStore(nodeDir);
    accountService = AccountServiceClient(
      baseUrl: '$accountServiceUrl/accounts',
      identity: myDevice,
    );
    pendingRequests = PendingFriendRequestCache();
    revocationQueue = PendingRevocationStore(nodeDir);
    poller = AccountUpdatePoller(
      sessionStore: sessionStore,
      friendSync: FriendSyncService(
        friendStore: friendStore,
        sessionStore: sessionStore,
        accountService: accountService,
      ),
      accountService: accountService,
      pendingRequests: pendingRequests,
      revocations: FriendRevocationService(
        sessionStore: sessionStore,
        accountService: accountService,
        store: revocationQueue,
      ),
      // Short enough that a handful of real ticks fit in a test, rather than
      // faking time. Every assertion below waits for an observable outcome,
      // never for a fixed number of milliseconds it hopes is enough.
      pollInterval: const Duration(milliseconds: 40),
    );

    accountServiceCalls.clear();
  });

  tearDown(() async {
    poller.stop();
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

  /// Waits for [condition], polling — never a fixed sleep that is either
  /// flaky or slow.
  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Condition not met in $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  group('a node with no session', () {
    test('makes zero account-service calls, however many times the timer '
        'fires', () async {
      await alicePendingRequest();
      accountServiceCalls.clear();

      poller.start();
      // ~12 ticks at 40ms. Each one that did anything at all would show up.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // The whole promise, structurally: not "the calls failed", not "their
      // results were discarded" -- there were none. A Musicat Server that
      // never logs in must cost the account service exactly what it did
      // before accounts existed.
      expect(accountServiceCalls, isEmpty);
      expect(pendingRequests.current.isKnown, isFalse);
      expect(await friendStore.loadAll(), isEmpty);
    });

    test('an explicit refreshNow() makes no call either, and says it did '
        'nothing', () async {
      expect(await poller.refreshNow(force: true), isFalse);
      expect(accountServiceCalls, isEmpty);
    });

    test('goes quiet again after a logout', () async {
      await logIn();
      await alicePendingRequest();
      expect(await poller.refreshNow(force: true), isTrue);
      expect(accountServiceCalls, isNotEmpty);

      await sessionStore.clear();
      accountServiceCalls.clear();
      poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(accountServiceCalls, isEmpty);
    });
  });

  group('a logged-in node', () {
    test('picks up a pending friend request on its own, with nothing having '
        'told it to', () async {
      await logIn();
      final requestId = await alicePendingRequest();
      accountServiceCalls.clear();

      poller.start();
      await waitUntil(() => pendingRequests.current.requests.isNotEmpty);

      final pending = pendingRequests.current;
      expect(pending.requests.single.id, requestId);
      // The username, not just the accountId -- an app cannot show the
      // latter to a human.
      expect(pending.requests.single.fromUsername, 'alice');
      expect(pending.requests.single.fromAccountId, aliceAccountId);
      expect(pending.isKnown, isTrue);
      expect(pending.fetchedAt, isNotNull);
    });

    test('picks up a friendship accepted elsewhere, so the local friend list '
        'converges without any push at all', () async {
      await logIn();
      final requestId = await alicePendingRequest();
      // I accept from some *other* device of my own account. This node is
      // told nothing.
      final accepted = await signedRequest(
        myDevice,
        'POST',
        '/accounts/$myAccountId/friend-requests/$requestId/accept',
      );
      expect(accepted.statusCode, 200);
      expect(await friendStore.loadAll(), isEmpty);

      poller.start();
      // The pending-request fetch runs *after* the friend sync in the same
      // pass, so this is a precise "one full pass has completed" signal --
      // no sleeping, and no race with a half-finished pass.
      await waitUntil(() => pendingRequests.current.isKnown);

      final alice = await friendStore.findByAccountId(aliceAccountId);
      expect(alice, isNotNull);
      expect(alice!.displayName, 'alice');
    });

    test('stop() really stops it', () async {
      await logIn();
      poller.start();
      await waitUntil(() => accountServiceCalls.isNotEmpty);

      poller.stop();
      expect(poller.isRunning, isFalse);
      accountServiceCalls.clear();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(accountServiceCalls, isEmpty);
    });

    test('an unreachable account service leaves the cached requests exactly '
        'as they were, rather than emptying them', () async {
      await logIn();
      await alicePendingRequest();
      expect(await poller.refreshNow(force: true), isTrue);
      expect(pendingRequests.current.requests, hasLength(1));
      final fetchedAt = pendingRequests.current.fetchedAt;

      await accountServer.close(force: true);
      expect(await poller.refreshNow(force: true), isTrue);

      // A moment of downtime must never look like "you have no friend
      // requests" -- that is a message a user would act on.
      expect(pendingRequests.current.requests, hasLength(1));
      expect(pendingRequests.current.fetchedAt, fetchedAt);
    });

    test('overlapping runs are skipped, not queued', () async {
      await logIn();
      final first = poller.refreshNow(force: true);
      final second = poller.refreshNow(force: true);

      expect(await first, isTrue);
      expect(
        await second,
        isFalse,
        reason:
            'A second run started while the first was in flight must be '
            'dropped, exactly as FriendDeviceRefresher.refreshAll does.',
      );
    });
  });

  group('outstanding revocations', () {
    /// Makes this node and Alice accepted friends on the account service.
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

    test('a tick flushes one that was queued while this node was offline -- '
        'the plane-landing case', () async {
      await logIn();
      await befriendAlice();
      // What `DELETE /api/v1/federation/friends/<id>` left behind when the
      // account service could not be reached at the time.
      await revocationQueue.enqueue(
        friendAccountId: aliceAccountId,
        asAccountId: myAccountId,
      );
      accountServiceCalls.clear();

      poller.start();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((await revocationQueue.loadAll()).isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        await friendRequestStore.areMutualFriends(myAccountId, aliceAccountId),
        isFalse,
        reason: 'the poller never flushed the queued revocation',
      );
      expect(await revocationQueue.loadAll(), isEmpty);
    });

    test(
      'a session-less node never flushes one, however long it runs',
      () async {
        await befriendAlice();
        await revocationQueue.enqueue(
          friendAccountId: aliceAccountId,
          asAccountId: myAccountId,
        );
        accountServiceCalls.clear();

        poller.start();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(accountServiceCalls, isEmpty);
        expect(
          await revocationQueue.loadAll(),
          hasLength(1),
          reason: 'logging out is not abandoning a revocation you owe',
        );
      },
    );
  });
}
