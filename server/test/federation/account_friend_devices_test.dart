import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:musicat_server/src/accounts/account.dart';
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_service_client.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/federation/account_friend_devices.dart';
import 'package:musicat_server/src/federation/federation_routes.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/pairing_code_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/nat/udp_puncher.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

/// Exercises the *only* two paths that are ever allowed to talk to the
/// account service — a cache miss on an unknown device, and the scheduled
/// refresh — against a real, live account service (`shelf_io.serve`,
/// mounted at the same `/accounts/` prefix `bin/relay.dart` uses), with
/// real Ed25519 identities and real Argon2id logins. No mocks anywhere.
void main() {
  late Directory accountsDir;
  late Directory nodeDir;
  late AccountStore accountStore;
  late FriendRequestStore friendRequestStore;
  late HttpServer accountServer;
  late String accountServiceUrl;
  late List<String> accountServiceCalls;

  late FriendStore friendStore;
  late AccountServiceClient accountService;
  late AccountFriendDeviceResolver resolver;
  late FriendDeviceRefresher refresher;

  late NodeIdentity myDevice;
  late NodeIdentity alicePhone;
  late NodeIdentity aliceDesktop;
  late NodeIdentity stranger;
  late String myAccountId;
  late String aliceAccountId;

  final identityDirs = <Directory>[];

  Future<NodeIdentity> newIdentity(String label) async {
    final dir = Directory.systemTemp.createTempSync('musicat_afd_${label}_');
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

  /// Signs up (or logs in) [identity] as a device of [username], through
  /// the real nonce + password + signature flow.
  Future<String> login(
    String username,
    String password,
    NodeIdentity identity, {
    String? relayUrl,
  }) async {
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
        'relayUrl': ?relayUrl,
      }),
    );
    expect(response.statusCode, anyOf(200, 201));
    return (jsonDecode(response.body) as Map<String, dynamic>)['accountId']
        as String;
  }

  Future<void> becomeMutualFriends() async {
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

  Future<FriendDevice> deviceOf(
    NodeIdentity identity, {
    String? address,
  }) async => FriendDevice(
    nodeId: identity.nodeId,
    publicKeyBase64: await identity.publicKeyBase64(),
    address: address,
  );

  Future<RequestVerification> verifySignedBy(
    NodeIdentity identity,
    RequestVerifier verifier,
  ) async {
    const path = '/api/v1/federation/ping';
    final headers = await RequestSigner(
      identity,
    ).sign(method: 'GET', path: path);
    return verifier.verify(
      method: 'GET',
      path: path,
      body: '',
      nodeId: headers['X-Node-Id'],
      timestamp: headers['X-Timestamp'],
      signatureBase64: headers['X-Signature'],
    );
  }

  setUp(() async {
    accountsDir = Directory.systemTemp.createTempSync('musicat_afd_accounts_');
    nodeDir = Directory.systemTemp.createTempSync('musicat_afd_node_');
    accountStore = AccountStore(accountsDir);
    friendRequestStore = FriendRequestStore(accountsDir);
    accountServiceCalls = [];

    // Mounted exactly the way bin/relay.dart mounts it, so the signed
    // paths these tests produce are the real production ones.
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
    stranger = await newIdentity('stranger');

    myAccountId = await login('bob', 'hunter2-correct', myDevice);
    aliceAccountId = await login('alice', 'hunter2-correct', alicePhone);
    await becomeMutualFriends();

    friendStore = FriendStore(nodeDir);
    accountService = AccountServiceClient(
      baseUrl: '$accountServiceUrl/accounts',
      identity: myDevice,
    );
    resolver = AccountFriendDeviceResolver(
      friendStore: friendStore,
      accountService: accountService,
    );
    refresher = FriendDeviceRefresher(
      friendStore: friendStore,
      accountService: accountService,
    );

    // This node knows Alice as an account friend, but only from her phone.
    await friendStore.add(
      Friend(
        accountId: aliceAccountId,
        devices: [await deviceOf(alicePhone, address: 'alice.example:8080')],
        displayName: 'Alice',
      ),
    );

    accountServiceCalls.clear();
  });

  tearDown(() async {
    refresher.stop();
    accountService.close();
    await accountServer.close(force: true);
    accountsDir.deleteSync(recursive: true);
    nodeDir.deleteSync(recursive: true);
    for (final dir in identityDirs) {
      dir.deleteSync(recursive: true);
    }
    identityDirs.clear();
  });

  group('the cache-miss path', () {
    test(
      "resolves a friend's newly-linked device, which then verifies",
      () async {
        // Alice logs in on her desktop for the first time. This node knows
        // nothing about it yet. (Her own login traffic isn't this node's --
        // drop it from the record before asserting on what *this* node
        // calls.)
        await login('alice', 'hunter2-correct', aliceDesktop);
        accountServiceCalls.clear();

        final offlineVerifier = RequestVerifier(friendStore);
        expect(
          (await verifySignedBy(aliceDesktop, offlineVerifier)).result,
          RequestVerificationResult.unknownNode,
        );
        expect(accountServiceCalls, isEmpty);

        final verifier = RequestVerifier(
          friendStore,
          unknownDeviceResolver: resolver,
        );
        final verification = await verifySignedBy(aliceDesktop, verifier);

        expect(verification.result, RequestVerificationResult.valid);
        // Resolved to the *account*, not to the new device.
        expect(verification.friendAccountId, aliceAccountId);
        expect(verification.deviceNodeId, aliceDesktop.nodeId);
        expect(accountServiceCalls, [
          '/accounts/by-device/${aliceDesktop.nodeId}',
          '/accounts/$aliceAccountId/devices',
        ]);

        // And it's cached now: a second request costs nothing.
        accountServiceCalls.clear();
        expect(
          (await verifySignedBy(aliceDesktop, verifier)).result,
          RequestVerificationResult.valid,
        );
        expect(accountServiceCalls, isEmpty);
        final cached = await friendStore.findByAccountId(aliceAccountId);
        expect(cached!.devices.map((d) => d.nodeId), {
          alicePhone.nodeId,
          aliceDesktop.nodeId,
        });
        // The phone's locally-learned address survived the refresh -- the
        // account service never knew it.
        expect(
          cached.deviceFor(alicePhone.nodeId)?.address,
          'alice.example:8080',
        );
      },
    );

    test('a repeated unknown nodeId does not hit the account service every '
        'time (negative cache)', () async {
      expect(await resolver.resolveUnknownDevice(stranger.nodeId), isFalse);
      expect(accountServiceCalls, hasLength(1));

      for (var i = 0; i < 5; i++) {
        expect(await resolver.resolveUnknownDevice(stranger.nodeId), isFalse);
      }

      expect(accountServiceCalls, hasLength(1));
    });

    test('the negative cache expires, allowing a later retry', () async {
      final quick = AccountFriendDeviceResolver(
        friendStore: friendStore,
        accountService: accountService,
        minLookupInterval: const Duration(milliseconds: 30),
      );

      await quick.resolveUnknownDevice(stranger.nodeId);
      await quick.resolveUnknownDevice(stranger.nodeId);
      expect(accountServiceCalls, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await quick.resolveUnknownDevice(stranger.nodeId);

      expect(accountServiceCalls, hasLength(2));
    });

    test('a flood of *distinct* unknown nodeIds is bounded by the global '
        'window cap', () async {
      final capped = AccountFriendDeviceResolver(
        friendStore: friendStore,
        accountService: accountService,
        maxLookupsPerWindow: 2,
      );

      for (var i = 0; i < 10; i++) {
        final fakeNodeId = 'made-up-node-$i';
        expect(await capped.resolveUnknownDevice(fakeNodeId), isFalse);
      }

      expect(accountServiceCalls, hasLength(2));
    });

    test(
      "a device of an account that isn't a friend is never adopted",
      () async {
        final carolDevice = await newIdentity('carol');
        await login('carol', 'hunter2-correct', carolDevice);
        accountServiceCalls.clear();

        expect(
          await resolver.resolveUnknownDevice(carolDevice.nodeId),
          isFalse,
        );

        // It looked up who the device belongs to, and stopped right there --
        // no device-list call, and certainly no new friend.
        expect(accountServiceCalls, hasLength(1));
        expect(await friendStore.loadAll(), hasLength(1));
        expect(
          await friendStore.findByDeviceNodeId(carolDevice.nodeId),
          isNull,
        );
      },
    );

    test('a legacy device-pinned friend is never resolved against the '
        'account service', () async {
      // Alice's phone, but recorded the old device-pinned way.
      final legacyDir = Directory.systemTemp.createTempSync('musicat_afd_leg_');
      final legacyStore = FriendStore(legacyDir);
      await legacyStore.add(
        Friend.devicePinned(
          nodeId: alicePhone.nodeId,
          publicKeyBase64: await alicePhone.publicKeyBase64(),
          address: 'alice.example:8080',
        ),
      );
      final legacyResolver = AccountFriendDeviceResolver(
        friendStore: legacyStore,
        accountService: accountService,
      );
      await login('alice', 'hunter2-correct', aliceDesktop);

      // Her *other* device stays unknown: a device-pinned friend is one
      // device, forever, exactly as before Fase 5.
      expect(
        await legacyResolver.resolveUnknownDevice(aliceDesktop.nodeId),
        isFalse,
      );
      expect((await legacyStore.loadAll()).single.devices, hasLength(1));

      legacyDir.deleteSync(recursive: true);
    });
  });

  group('the periodic refresh', () {
    test('picks up a newly-linked device', () async {
      await login('alice', 'hunter2-correct', aliceDesktop);

      expect(await refresher.refreshAll(), 1);

      final cached = await friendStore.findByAccountId(aliceAccountId);
      expect(cached!.devices.map((d) => d.nodeId), {
        alicePhone.nodeId,
        aliceDesktop.nodeId,
      });
      expect(cached.devicesRefreshedAt, isNotNull);
    });

    test(
      'drops a device that was unlinked, so revocation propagates',
      () async {
        await login('alice', 'hunter2-correct', aliceDesktop);
        await refresher.refreshAll();

        final verifier = RequestVerifier(friendStore);
        expect(
          (await verifySignedBy(alicePhone, verifier)).result,
          RequestVerificationResult.valid,
        );

        // Alice unlinks the phone from her desktop (the lost-phone flow).
        final unlinked = await signedRequest(
          aliceDesktop,
          'DELETE',
          '/accounts/$aliceAccountId/devices/${alicePhone.nodeId}',
        );
        expect(unlinked.statusCode, 204);

        await refresher.refreshAll();

        expect(
          (await verifySignedBy(alicePhone, verifier)).result,
          RequestVerificationResult.unknownNode,
        );
        expect(
          (await verifySignedBy(aliceDesktop, verifier)).result,
          RequestVerificationResult.valid,
        );
      },
    );

    test('skips legacy device-pinned friends entirely', () async {
      await friendStore.add(
        Friend.devicePinned(
          nodeId: stranger.nodeId,
          publicKeyBase64: await stranger.publicKeyBase64(),
          address: 'legacy.example:8080',
        ),
      );
      accountServiceCalls.clear();

      await refresher.refreshAll();

      // Exactly one device-list call: Alice's account. Nothing at all for
      // the device-pinned entry.
      expect(accountServiceCalls, ['/accounts/$aliceAccountId/devices']);
    });

    test('leaves the cache exactly as it was when the account service is '
        'unreachable -- no false rejections', () async {
      await accountServer.close(force: true);

      expect(await refresher.refreshAll(), 0);

      final cached = await friendStore.findByAccountId(aliceAccountId);
      expect(cached!.devices.map((d) => d.nodeId), {alicePhone.nodeId});
      expect(
        (await verifySignedBy(alicePhone, RequestVerifier(friendStore))).result,
        RequestVerificationResult.valid,
      );
    });

    test(
      'start() actually runs it on its interval, and stop() stops it',
      () async {
        await login('alice', 'hunter2-correct', aliceDesktop);
        final ticking = FriendDeviceRefresher(
          friendStore: friendStore,
          accountService: accountService,
          refreshInterval: const Duration(milliseconds: 30),
        )..start();
        expect(ticking.isRunning, isTrue);

        // Deterministic in outcome, not in timing: poll until the scheduled
        // run has actually happened rather than sleeping a fixed guess.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        var devices = <String>{};
        while (DateTime.now().isBefore(deadline) && devices.length < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final cached = await friendStore.findByAccountId(aliceAccountId);
          devices = {for (final d in cached!.devices) d.nodeId};
        }
        expect(devices, {alicePhone.nodeId, aliceDesktop.nodeId});

        ticking.stop();
        expect(ticking.isRunning, isFalse);
        accountServiceCalls.clear();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(accountServiceCalls, isEmpty);
      },
    );
  });

  group('tombstones survive every kind of sync', () {
    test(
      'a refresh never resurrects a friend that was removed locally',
      () async {
        await friendStore.remove(aliceAccountId);
        expect(await friendStore.loadAll(), isEmpty);
        accountServiceCalls.clear();

        expect(await refresher.refreshAll(), 0);
        expect(await refresher.refresh(aliceAccountId), isFalse);

        expect(await friendStore.loadAll(), isEmpty);
        expect(await friendStore.findByAccountId(aliceAccountId), isNull);
        // It didn't even ask: the tombstone short-circuits before any call.
        expect(accountServiceCalls, isEmpty);
      },
    );

    test('the cache-miss path never resurrects one either, even though the '
        'account service still lists their devices', () async {
      await login('alice', 'hunter2-correct', aliceDesktop);
      await friendStore.remove(aliceAccountId);

      expect(await resolver.resolveUnknownDevice(aliceDesktop.nodeId), isFalse);

      expect(await friendStore.loadAll(), isEmpty);
      final verifier = RequestVerifier(
        friendStore,
        unknownDeviceResolver: resolver,
      );
      expect(
        (await verifySignedBy(aliceDesktop, verifier)).result,
        RequestVerificationResult.unknownNode,
      );
      expect(
        (await verifySignedBy(alicePhone, verifier)).result,
        RequestVerificationResult.unknownNode,
      );
    });

    test(
      'removing a friend does not need the account service at all',
      () async {
        await accountServer.close(force: true);

        await friendStore.remove(aliceAccountId);

        expect(await friendStore.loadAll(), isEmpty);
        expect(await friendStore.isRemoved(aliceAccountId), isTrue);
        expect(
          (await verifySignedBy(
            alicePhone,
            RequestVerifier(friendStore),
          )).result,
          RequestVerificationResult.unknownNode,
        );
      },
    );

    test(
      're-adding them explicitly works, and refreshes normally again',
      () async {
        await friendStore.remove(aliceAccountId);
        await login('alice', 'hunter2-correct', aliceDesktop);

        await friendStore.add(
          Friend(
            accountId: aliceAccountId,
            devices: [
              await deviceOf(alicePhone, address: 'alice.example:8080'),
            ],
          ),
        );

        expect(await refresher.refresh(aliceAccountId), isTrue);
        final cached = await friendStore.findByAccountId(aliceAccountId);
        expect(cached!.devices, hasLength(2));
      },
    );
  });

  /// The reachability gap ADR 0050 named, closed. These are the pure-function
  /// half; the end-to-end half (two real servers reaching each other over a
  /// real relay, with no address anywhere) is
  /// `account_relay_reachability_test.dart`.
  group('mergeFriendDevices -- the two sources of relayUrl', () {
    DeviceLink authoritative({String? relayUrl}) => DeviceLink(
      nodeId: 'node-1',
      publicKeyBase64: 'key-1',
      linkedAt: DateTime.utc(2026, 1, 1),
      relayUrl: relayUrl,
    );

    test("adopts the account service's relayUrl for a device this node has "
        'never paired with -- the whole point of round B', () {
      final merged = mergeFriendDevices(const <FriendDevice>[], [
        authoritative(relayUrl: 'ws://relay.example:8090/connect'),
      ]);

      expect(merged.single.relayUrl, 'ws://relay.example:8090/connect');
      // ...and still nothing the account service does not record.
      expect(merged.single.address, isNull);
      expect(merged.single.udpCandidate, isNull);
    });

    test('prefers a locally-learned relay over the authoritative one', () {
      final merged = mergeFriendDevices(
        const [
          FriendDevice(
            nodeId: 'node-1',
            publicKeyBase64: 'key-1',
            relayUrl: 'ws://paired-relay.example/connect',
          ),
        ],
        [authoritative(relayUrl: 'ws://account-service-says.example/connect')],
      );

      expect(merged.single.relayUrl, 'ws://paired-relay.example/connect');
    });

    test('falls back to the authoritative relay when the cached device has '
        'none, rather than leaving the device unreachable forever', () {
      final merged = mergeFriendDevices(
        const [
          FriendDevice(
            nodeId: 'node-1',
            publicKeyBase64: 'key-1',
            address: 'paired.example:8080',
          ),
        ],
        [authoritative(relayUrl: 'ws://account-service-says.example/connect')],
      );

      expect(
        merged.single.relayUrl,
        'ws://account-service-says.example/connect',
      );
      // The locally-learned address is untouched -- that half is still
      // local-only, and it still comes first in reachability order.
      expect(merged.single.address, 'paired.example:8080');
    });

    test('leaves address and udpCandidate strictly local -- an authoritative '
        'device can never introduce either', () {
      final merged = mergeFriendDevices(
        const [
          FriendDevice(
            nodeId: 'node-1',
            publicKeyBase64: 'key-1',
            address: '192.168.1.5:8080',
            udpCandidate: '203.0.113.7:41234',
          ),
        ],
        [authoritative()],
      );

      expect(merged.single.address, '192.168.1.5:8080');
      expect(merged.single.udpCandidate, '203.0.113.7:41234');
      expect(merged.single.relayUrl, isNull);
    });
  });

  group("a friend's relay, learned from the account service", () {
    test('arrives on the periodic device refresh, so an account-only friend '
        'becomes reachable without ever pairing', () async {
      // Alice's *new* device publishes a relay when it logs in. This node has
      // never paired with it and knows no address for it.
      await login(
        'alice',
        'hunter2-correct',
        aliceDesktop,
        relayUrl: 'ws://alice-relay.example:8090/connect',
      );

      expect(await refresher.refreshAll(), 1);

      final cached = await friendStore.findByAccountId(aliceAccountId);
      final desktop = cached!.deviceFor(aliceDesktop.nodeId)!;
      expect(desktop.address, isNull);
      expect(desktop.relayUrl, 'ws://alice-relay.example:8090/connect');
    });

    test('does not overwrite the relay this node learned by pairing with '
        'that same device', () async {
      // The locally-cached phone was paired with, and reported a relay then.
      await friendStore.updateDevices(aliceAccountId, [
        FriendDevice(
          nodeId: alicePhone.nodeId,
          publicKeyBase64: await alicePhone.publicKeyBase64(),
          address: 'alice.example:8080',
          relayUrl: 'ws://paired-relay.example:8090/connect',
        ),
      ]);
      // Alice re-logs in from that same phone, now publishing a different one.
      await login(
        'alice',
        'hunter2-correct',
        alicePhone,
        relayUrl: 'ws://account-service-relay.example:8090/connect',
      );

      await refresher.refreshAll();

      final cached = await friendStore.findByAccountId(aliceAccountId);
      expect(
        cached!.deviceFor(alicePhone.nodeId)!.relayUrl,
        'ws://paired-relay.example:8090/connect',
      );
    });

    test('a re-login with no relay clears it on the account service, so a '
        'stale endpoint is never served to friends', () async {
      await login(
        'alice',
        'hunter2-correct',
        aliceDesktop,
        relayUrl: 'ws://alice-relay.example:8090/connect',
      );
      expect(
        (await accountStore.findById(
          aliceAccountId,
        ))!.devices.firstWhere((d) => d.nodeId == aliceDesktop.nodeId).relayUrl,
        'ws://alice-relay.example:8090/connect',
      );

      await login('alice', 'hunter2-correct', aliceDesktop);

      expect(
        (await accountStore.findById(
          aliceAccountId,
        ))!.devices.firstWhere((d) => d.nodeId == aliceDesktop.nodeId).relayUrl,
        isNull,
      );
    });
  });

  group('POST /friends with a claimed accountId', () {
    late Directory pairingDir;
    late FriendStore pairingFriends;
    late UdpPuncher puncher;
    late HttpServer nodeServer;
    late String nodeUrl;

    Future<void> startNode({AccountServiceClient? withAccountService}) async {
      final router = Router()
        ..mount(
          '/api/v1/federation/',
          buildFederationRouter(
            pairingFriends,
            RequestVerifier(pairingFriends),
            PairingCodeStore(),
            puncher,
            accountService: withAccountService,
          ).call,
        );
      nodeServer = await shelf_io.serve(router.call, 'localhost', 0);
      nodeUrl = 'http://localhost:${nodeServer.port}/api/v1/federation';
    }

    Future<String> pairingCode() async {
      final response = await http.post(Uri.parse('$nodeUrl/pairing-codes'));
      return (jsonDecode(response.body) as Map<String, dynamic>)['code']
          as String;
    }

    Future<http.Response> pair(
      NodeIdentity identity, {
      required String? claimedAccountId,
    }) async => http.post(
      Uri.parse('$nodeUrl/friends'),
      body: jsonEncode({
        'code': await pairingCode(),
        'nodeId': identity.nodeId,
        'publicKeyBase64': await identity.publicKeyBase64(),
        'address': 'peer.example:8080',
        'accountId': ?claimedAccountId,
      }),
    );

    setUp(() async {
      pairingDir = Directory.systemTemp.createTempSync('musicat_afd_pair_');
      pairingFriends = FriendStore(pairingDir);
      puncher = UdpPuncher(identity: myDevice, friendStore: pairingFriends);
      await puncher.bind();
    });

    tearDown(() async {
      await nodeServer.close(force: true);
      await puncher.close();
      pairingDir.deleteSync(recursive: true);
    });

    test(
      'a claim the account service confirms creates an account friend',
      () async {
        await startNode(withAccountService: accountService);

        final response = await pair(
          alicePhone,
          claimedAccountId: aliceAccountId,
        );

        expect(response.statusCode, 201);
        expect(
          (jsonDecode(response.body) as Map<String, dynamic>)['accountId'],
          aliceAccountId,
        );
        final friend = await pairingFriends.findByAccountId(aliceAccountId);
        expect(friend, isNotNull);
        expect(friend!.isDevicePinned, isFalse);
        expect(friend.devices.single.nodeId, alicePhone.nodeId);
        expect(friend.devices.single.address, 'peer.example:8080');
      },
    );

    test(
      'a claim the account service contradicts is rejected outright',
      () async {
        await startNode(withAccountService: accountService);

        // Alice's phone claiming to be *my* account.
        final response = await pair(alicePhone, claimedAccountId: myAccountId);

        expect(response.statusCode, 403);
        expect(await pairingFriends.loadAll(), isEmpty);
      },
    );

    test('a claim that cannot be confirmed (no account service configured) '
        'falls back to an ordinary device-pinned friend', () async {
      await startNode();

      final response = await pair(alicePhone, claimedAccountId: aliceAccountId);

      expect(response.statusCode, 201);
      expect(
        (jsonDecode(response.body) as Map<String, dynamic>)['accountId'],
        isNull,
      );
      final friend = await pairingFriends.findByDeviceNodeId(alicePhone.nodeId);
      expect(friend!.isDevicePinned, isTrue);
      expect(friend.accountId, alicePhone.nodeId);
    });

    test('pairing without claiming an account is unchanged, and never calls '
        'the account service', () async {
      await startNode(withAccountService: accountService);
      accountServiceCalls.clear();

      final response = await pair(alicePhone, claimedAccountId: null);

      expect(response.statusCode, 201);
      expect(accountServiceCalls, isEmpty);
      final friend = await pairingFriends.findByDeviceNodeId(alicePhone.nodeId);
      expect(friend!.isDevicePinned, isTrue);
    });

    test('an invalid pairing code is rejected before the account service is '
        'ever consulted', () async {
      await startNode(withAccountService: accountService);
      accountServiceCalls.clear();

      final response = await http.post(
        Uri.parse('$nodeUrl/friends'),
        body: jsonEncode({
          'code': 'not-a-real-code',
          'nodeId': alicePhone.nodeId,
          'publicKeyBase64': await alicePhone.publicKeyBase64(),
          'address': 'peer.example:8080',
          'accountId': aliceAccountId,
        }),
      );

      expect(response.statusCode, 403);
      expect(accountServiceCalls, isEmpty);
    });
  });
}
