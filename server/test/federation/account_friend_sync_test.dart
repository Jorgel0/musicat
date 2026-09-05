import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_service_client.dart';
import 'package:musicat_server/src/accounts/account_session_store.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/federation/account_friend_sync.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_reachability.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

/// [FriendSyncService] against a real, live account service (`shelf_io.serve`
/// at the same `/accounts/` prefix `bin/relay.dart` uses), with real Ed25519
/// identities, real Argon2id logins and real accepted friend requests. No
/// mocks — the same standard `account_friend_devices_test.dart` sets for the
/// device-refresh half of this bridge.
///
/// The load-bearing tests here are the ones that prove what this sync is
/// *not* allowed to do: resurrect a tombstoned friend, touch a device-pinned
/// one, remove anybody, or make a single network call with no session.
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
  late FriendSyncService sync;

  late NodeIdentity myDevice;
  late NodeIdentity alicePhone;
  late NodeIdentity aliceDesktop;
  late NodeIdentity bobPhone;
  late String myAccountId;
  late String aliceAccountId;
  late String bobAccountId;

  final identityDirs = <Directory>[];

  Future<NodeIdentity> newIdentity(String label) async {
    final dir = Directory.systemTemp.createTempSync('musicat_afs_${label}_');
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
      'DELETE' => http.delete(uri, headers: headers),
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

  /// Runs the full request/accept handshake so [me] and [otherUsername] are
  /// accepted friends on the account service.
  Future<void> befriend({
    required NodeIdentity meDevice,
    required String meAccountId,
    required String otherUsername,
    required NodeIdentity otherDevice,
    required String otherAccountId,
  }) async {
    final sent = await signedRequest(
      meDevice,
      'POST',
      '/accounts/$meAccountId/friend-requests',
      body: {'toUsername': otherUsername},
    );
    expect(sent.statusCode, 201);
    final requestId =
        (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;
    final accepted = await signedRequest(
      otherDevice,
      'POST',
      '/accounts/$otherAccountId/friend-requests/$requestId/accept',
    );
    expect(accepted.statusCode, 200);
  }

  setUp(() async {
    accountsDir = Directory.systemTemp.createTempSync('musicat_afs_accounts_');
    nodeDir = Directory.systemTemp.createTempSync('musicat_afs_node_');
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
    aliceDesktop = await newIdentity('alice_desktop');
    bobPhone = await newIdentity('bob_phone');

    myAccountId = await login('jorge', 'hunter2-correct', myDevice);
    aliceAccountId = await login('alice', 'hunter2-correct', alicePhone);
    bobAccountId = await login('bob', 'hunter2-correct', bobPhone);

    friendStore = FriendStore(nodeDir);
    sessionStore = AccountSessionStore(nodeDir);
    accountService = AccountServiceClient(
      baseUrl: '$accountServiceUrl/accounts',
      identity: myDevice,
    );
    sync = FriendSyncService(
      friendStore: friendStore,
      sessionStore: sessionStore,
      accountService: accountService,
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

  /// Logs this node in as its own account, which is what every sync below
  /// (except the no-session ones) needs on disk first.
  Future<void> logIn() =>
      sessionStore.save(accountId: myAccountId, username: 'jorge');

  Future<void> befriendAlice() => befriend(
    meDevice: myDevice,
    meAccountId: myAccountId,
    otherUsername: 'alice',
    otherDevice: alicePhone,
    otherAccountId: aliceAccountId,
  );

  group('with no session', () {
    test('sync() makes zero network calls', () async {
      await befriendAlice();
      accountServiceCalls.clear();

      final result = await sync.sync();

      expect(result.status, FriendSyncStatus.noSession);
      expect(result.attempted, isFalse);
      // The load-bearing assertion: not "the call failed", not "the result
      // was discarded" -- the account service was never asked at all. A node
      // that never logs in behaves exactly as it did before accounts.
      expect(accountServiceCalls, isEmpty);
      expect(await friendStore.loadAll(), isEmpty);
    });

    test('sync() still makes zero calls after a logout', () async {
      await logIn();
      await befriendAlice();
      await sync.sync(force: true);
      expect(await friendStore.loadAll(), hasLength(1));

      await sessionStore.clear();
      accountServiceCalls.clear();

      expect((await sync.sync(force: true)).status, FriendSyncStatus.noSession);
      expect(accountServiceCalls, isEmpty);
      // Logging out is not unfriending: the friend is still right there.
      expect(await friendStore.loadAll(), hasLength(1));
    });
  });

  group('learning new friends', () {
    test(
      'adds an accepted friend, from either direction of the request',
      () async {
        await logIn();
        // I sent this one...
        await befriendAlice();
        // ...and Bob sent this one to me.
        await befriend(
          meDevice: bobPhone,
          meAccountId: bobAccountId,
          otherUsername: 'jorge',
          otherDevice: myDevice,
          otherAccountId: myAccountId,
        );

        final result = await sync.sync();

        expect(result.status, FriendSyncStatus.completed);
        expect(result.added, 2);
        final friends = await friendStore.loadAll();
        expect(
          {for (final friend in friends) friend.accountId},
          {aliceAccountId, bobAccountId},
        );
        final alice = await friendStore.findByAccountId(aliceAccountId);
        expect(alice!.displayName, 'alice');
        expect(alice.isDevicePinned, isFalse);
        expect(alice.devices.single.nodeId, alicePhone.nodeId);
        expect(alice.devices.single.publicKeyBase64, isNotEmpty);
      },
    );

    test("a new friend's devices arrive with keys but no address at all -- "
        'the product gap this round names rather than hides', () async {
      await logIn();
      await befriendAlice();
      await sync.sync();

      final alice = (await friendStore.findByAccountId(aliceAccountId))!;
      expect(alice.devices.single.address, isNull);
      expect(alice.devices.single.relayUrl, isNull);
      expect(alice.devices.single.udpCandidate, isNull);

      // So this node can *verify* her, but cannot *initiate* to her. That
      // has to fail cleanly and immediately -- not hang, not crash.
      final stopwatch = Stopwatch()..start();
      await expectLater(
        reachFriend(http.Client(), alice, '/api/v1/sharing/shared-tracks'),
        throwsA(isA<FriendUnreachableException>()),
      );
      stopwatch.stop();
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 1)),
        reason:
            'No candidates means no attempt to time out; this must fail '
            'fast, not sit through a connect timeout.',
      );
    });

    test('an established friend keeps verifying after the sync learns them '
        'again -- the sync is not allowed to blank their keys', () async {
      await logIn();
      await befriendAlice();
      await login('alice', 'hunter2-correct', aliceDesktop);

      await sync.sync();

      final alice = (await friendStore.findByAccountId(aliceAccountId))!;
      expect(
        {for (final device in alice.devices) device.nodeId},
        {alicePhone.nodeId, aliceDesktop.nodeId},
      );
      final verifier = RequestVerifier(friendStore);
      const path = '/api/v1/federation/ping';
      final headers = await RequestSigner(
        aliceDesktop,
      ).sign(method: 'GET', path: path);
      final verification = await verifier.verify(
        method: 'GET',
        path: path,
        body: '',
        nodeId: headers['X-Node-Id'],
        timestamp: headers['X-Timestamp'],
        signatureBase64: headers['X-Signature'],
      );
      expect(verification.result, RequestVerificationResult.valid);
      expect(verification.friendAccountId, aliceAccountId);
    });

    test('never adds the logged-in account itself as its own friend', () async {
      await logIn();
      await befriendAlice();
      // A malicious/buggy service naming the caller in its own friend list.
      // Rather than mock the service, assert the invariant directly: the
      // synced list never contains this node's own account.
      await sync.sync();

      expect(await friendStore.findByAccountId(myAccountId), isNull);
    });
  });

  group('refreshing friends this node already has', () {
    test("merges devices, preserving a locally-learned address the account "
        'service has never heard of', () async {
      await logIn();
      await befriendAlice();
      await friendStore.add(
        Friend(
          accountId: aliceAccountId,
          devices: [
            FriendDevice(
              nodeId: alicePhone.nodeId,
              publicKeyBase64: await alicePhone.publicKeyBase64(),
              address: 'alice.example:8080',
              relayUrl: 'ws://relay.example:8090/connect',
            ),
          ],
          displayName: 'Alice',
          localNickname: 'best friend',
        ),
      );
      await login('alice', 'hunter2-correct', aliceDesktop);

      final result = await sync.sync();

      expect(result.added, 0);
      expect(result.updated, 1);
      final alice = (await friendStore.findByAccountId(aliceAccountId))!;
      expect(alice.devices, hasLength(2));
      expect(alice.deviceFor(alicePhone.nodeId)!.address, 'alice.example:8080');
      expect(
        alice.deviceFor(alicePhone.nodeId)!.relayUrl,
        'ws://relay.example:8090/connect',
      );
      expect(alice.deviceFor(aliceDesktop.nodeId)!.address, isNull);
      // Purely local labels are the user's, not the account service's.
      expect(alice.localNickname, 'best friend');
      expect(alice.displayName, 'Alice');
    });
  });

  group('rule 2: unfriending sticks', () {
    test(
      'a tombstoned account is NOT resurrected by a sync that lists them',
      () async {
        await logIn();
        await befriendAlice();
        await sync.sync(force: true);
        expect(await friendStore.findByAccountId(aliceAccountId), isNotNull);

        // The user removes her locally. The account service still says they
        // are accepted friends -- nothing about that changed.
        await friendStore.remove(aliceAccountId);
        expect(await friendStore.isRemoved(aliceAccountId), isTrue);

        final result = await sync.sync(force: true);

        expect(result.status, FriendSyncStatus.completed);
        expect(result.added, 0);
        expect(result.skipped, 1);
        expect(await friendStore.findByAccountId(aliceAccountId), isNull);
        expect(await friendStore.loadAll(), isEmpty);
        // And the tombstone survives, so the *next* sync refuses her too.
        expect(await friendStore.isRemoved(aliceAccountId), isTrue);
        await sync.sync(force: true);
        expect(await friendStore.loadAll(), isEmpty);
      },
    );

    test('the refusal holds even when the removal lands mid-sync -- the '
        'check that matters is inside the store lock', () async {
      await logIn();
      await befriendAlice();

      // Racing a remove() against a sync() that is about to add her. The
      // FriendStore-level check is what makes every interleaving safe; a
      // caller-side isRemoved() before an add() would leave a window here.
      final syncing = sync.sync(force: true);
      final removing = friendStore.remove(aliceAccountId);
      await Future.wait<Object?>([syncing, removing]);

      expect(await friendStore.isRemoved(aliceAccountId), isTrue);
      expect(
        await friendStore.findByAccountId(aliceAccountId),
        isNull,
        reason: 'a sync resurrected a friend removed while it ran',
      );
    });

    test('re-adding a removed friend explicitly works, and the sync updates '
        'them normally again', () async {
      await logIn();
      await befriendAlice();
      await sync.sync(force: true);
      await friendStore.remove(aliceAccountId);

      // The user pairs with her again -- the explicit local decision, which
      // is the only thing that clears a tombstone.
      await friendStore.add(
        Friend(
          accountId: aliceAccountId,
          devices: [
            FriendDevice(
              nodeId: alicePhone.nodeId,
              publicKeyBase64: await alicePhone.publicKeyBase64(),
              address: 'alice.example:8080',
            ),
          ],
        ),
      );
      await login('alice', 'hunter2-correct', aliceDesktop);

      final result = await sync.sync(force: true);

      expect(result.updated, 1);
      expect(
        (await friendStore.findByAccountId(aliceAccountId))!.devices,
        hasLength(2),
      );
    });
  });

  group('rule 3: legacy device-pinned friends are untouchable', () {
    test('a friend paired out-of-band is left alone, keeping the only '
        'address anybody has for them', () async {
      await logIn();
      await befriendAlice();
      // Alice is already a device-pinned friend here: paired by QR/code
      // before either of us had an account.
      await friendStore.add(
        Friend.devicePinned(
          nodeId: alicePhone.nodeId,
          publicKeyBase64: await alicePhone.publicKeyBase64(),
          address: 'alice.example:8080',
        ),
      );

      final result = await sync.sync();

      expect(result.added, 0);
      expect(result.skipped, 1);
      final friends = await friendStore.loadAll();
      expect(friends, hasLength(1));
      expect(friends.single.isDevicePinned, isTrue);
      expect(friends.single.accountId, alicePhone.nodeId);
      // The whole point: still reachable, which an account-based entry
      // built from the account service would not have been.
      expect(friends.single.devices.single.address, 'alice.example:8080');
      expect(await friendStore.findByAccountId(aliceAccountId), isNull);
    });
  });

  group('additive only', () {
    test('a local friend absent from the accepted list is left completely '
        'alone', () async {
      await logIn();
      // Bob is a local friend, with an address, whom this account has never
      // exchanged a friend request with.
      await friendStore.add(
        Friend(
          accountId: bobAccountId,
          devices: [
            FriendDevice(
              nodeId: bobPhone.nodeId,
              publicKeyBase64: await bobPhone.publicKeyBase64(),
              address: 'bob.example:8080',
            ),
          ],
          displayName: 'Bob',
        ),
      );
      await befriendAlice();

      final result = await sync.sync();

      expect(result.added, 1);
      final bob = await friendStore.findByAccountId(bobAccountId);
      expect(bob, isNotNull, reason: 'the sync removed a local friend');
      expect(bob!.devices.single.address, 'bob.example:8080');
      expect(bob.displayName, 'Bob');
    });

    test('an empty accepted list removes nothing', () async {
      await logIn();
      await friendStore.add(
        Friend(
          accountId: bobAccountId,
          devices: [
            FriendDevice(
              nodeId: bobPhone.nodeId,
              publicKeyBase64: await bobPhone.publicKeyBase64(),
              address: 'bob.example:8080',
            ),
          ],
        ),
      );

      final result = await sync.sync();

      expect(result.status, FriendSyncStatus.completed);
      expect(result.added, 0);
      expect(await friendStore.loadAll(), hasLength(1));
    });
  });

  group('failure and throttling', () {
    test('an unreachable account service leaves the local cache exactly as '
        'it was', () async {
      await logIn();
      await friendStore.add(
        Friend(
          accountId: bobAccountId,
          devices: [
            FriendDevice(
              nodeId: bobPhone.nodeId,
              publicKeyBase64: await bobPhone.publicKeyBase64(),
              address: 'bob.example:8080',
            ),
          ],
        ),
      );
      await accountServer.close(force: true);

      final result = await sync.sync();

      expect(result.status, FriendSyncStatus.unreachable);
      expect(result.fetched, isFalse);
      final friends = await friendStore.loadAll();
      expect(friends, hasLength(1));
      expect(friends.single.devices.single.address, 'bob.example:8080');
    });

    test('a 403 (this device not linked to that account) changes nothing '
        'either', () async {
      // A session claiming an account this device is *not* a device of --
      // the shape a stale or hand-edited session file would have.
      await sessionStore.save(accountId: aliceAccountId, username: 'alice');
      accountServiceCalls.clear();

      final result = await sync.sync();

      expect(result.status, FriendSyncStatus.unreachable);
      expect(accountServiceCalls, ['/accounts/$aliceAccountId/friends']);
      expect(await friendStore.loadAll(), isEmpty);
    });

    test('an unforced second sync inside minSyncInterval is throttled, and '
        'force skips the throttle', () async {
      await logIn();
      await befriendAlice();

      expect((await sync.sync()).status, FriendSyncStatus.completed);
      accountServiceCalls.clear();

      expect((await sync.sync()).status, FriendSyncStatus.throttled);
      expect(accountServiceCalls, isEmpty);

      expect((await sync.sync(force: true)).status, FriendSyncStatus.completed);
      expect(accountServiceCalls, ['/accounts/$myAccountId/friends']);
    });

    test(
      'an already-running sync is skipped rather than interleaved',
      () async {
        await logIn();
        await befriendAlice();

        final results = await Future.wait([
          sync.sync(force: true),
          sync.sync(force: true),
        ]);

        expect(
          results.map((r) => r.status),
          containsAll([FriendSyncStatus.completed, FriendSyncStatus.throttled]),
        );
        expect(await friendStore.loadAll(), hasLength(1));
      },
    );
  });
}
