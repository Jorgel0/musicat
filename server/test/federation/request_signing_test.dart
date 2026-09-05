import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/federation/unknown_device_resolver.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:test/test.dart';

/// A resolver that records every call and never learns anything — stands in
/// for "the account service is configured" without going anywhere near a
/// network. The real, networked one is exercised for real against a live
/// account service in `account_friend_devices_test.dart`.
class _RecordingResolver implements UnknownDeviceResolver {
  final List<String> calls = [];

  @override
  Future<bool> resolveUnknownDevice(String nodeId) async {
    calls.add(nodeId);
    return false;
  }
}

void main() {
  late Directory aliceDir;
  late Directory bobDir;
  late NodeIdentity alice;
  late NodeIdentity bob;
  late FriendStore bobsFriends;
  late RequestVerifier verifier;

  setUp(() async {
    aliceDir = Directory.systemTemp.createTempSync('musicat_signing_alice_');
    bobDir = Directory.systemTemp.createTempSync('musicat_signing_bob_');
    alice = await NodeIdentityStore(aliceDir).loadOrCreate();
    bob = await NodeIdentityStore(bobDir).loadOrCreate();

    // Bob trusts Alice.
    bobsFriends = FriendStore(bobDir);
    await bobsFriends.add(
      Friend.devicePinned(
        nodeId: alice.nodeId,
        publicKeyBase64: await alice.publicKeyBase64(),
        address: 'alice.example:8080',
      ),
    );
    verifier = RequestVerifier(bobsFriends);
  });

  tearDown(() {
    aliceDir.deleteSync(recursive: true);
    bobDir.deleteSync(recursive: true);
  });

  Future<RequestVerification> verifySignedBy(
    NodeIdentity identity, {
    String path = '/api/v1/federation/ping',
    String verifyPath = '/api/v1/federation/ping',
    RequestVerifier? using,
  }) async {
    final headers = await RequestSigner(
      identity,
    ).sign(method: 'GET', path: path);
    return (using ?? verifier).verify(
      method: 'GET',
      path: verifyPath,
      body: '',
      nodeId: headers['X-Node-Id'],
      timestamp: headers['X-Timestamp'],
      signatureBase64: headers['X-Signature'],
    );
  }

  test('a request signed by a known friend verifies as valid', () async {
    final verification = await verifySignedBy(alice);

    expect(verification.result, RequestVerificationResult.valid);
    expect(verification.isValid, isTrue);
    // A device-pinned friend's account id is their own nodeId, which is
    // what keeps every existing authorization rule meaning the same thing.
    expect(verification.friendAccountId, alice.nodeId);
    expect(verification.deviceNodeId, alice.nodeId);
  });

  test('rejects a request from a node that is not a friend', () async {
    final verification = await verifySignedBy(bob);

    expect(verification.result, RequestVerificationResult.unknownNode);
    expect(verification.friendAccountId, isNull);
  });

  test('rejects a tampered path (signature no longer matches)', () async {
    final verification = await verifySignedBy(
      alice,
      verifyPath: '/api/v1/federation/friends', // not what was signed
    );

    expect(verification.result, RequestVerificationResult.invalidSignature);
    expect(verification.friendAccountId, isNull);
  });

  test('rejects a stale timestamp', () async {
    final staleTimestamp = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 10))
        .toIso8601String();
    final message = canonicalRequestString(
      method: 'GET',
      path: '/api/v1/federation/ping',
      timestamp: staleTimestamp,
      body: '',
    );
    final signatureBase64 = base64Encode(
      await alice.sign(utf8.encode(message)),
    );

    final verification = await verifier.verify(
      method: 'GET',
      path: '/api/v1/federation/ping',
      body: '',
      nodeId: alice.nodeId,
      timestamp: staleTimestamp,
      signatureBase64: signatureBase64,
    );

    expect(verification.result, RequestVerificationResult.staleTimestamp);
  });

  test(
    'revoking a friend makes their previously-valid signature fail',
    () async {
      await bobsFriends.remove(alice.nodeId);

      final verification = await verifySignedBy(alice);

      expect(verification.result, RequestVerificationResult.unknownNode);
    },
  );

  group('a legacy friends.json written before accounts existed', () {
    late Directory legacyDir;
    late RequestVerifier legacyVerifier;

    setUp(() async {
      legacyDir = Directory.systemTemp.createTempSync('musicat_signing_old_');
      // Hand-written in the *old* format on purpose (no accountId, no
      // devices list) -- the whole point is that nothing produced by the
      // new code is involved in creating it.
      File('${legacyDir.path}/friends.json').writeAsStringSync(
        jsonEncode([
          {
            'nodeId': alice.nodeId,
            'publicKeyBase64': await alice.publicKeyBase64(),
            'address': 'alice.example:8080',
            'displayName': 'Alice',
            'udpCandidate': null,
            'relayUrl': null,
            'localNickname': null,
          },
        ]),
      );
      legacyVerifier = RequestVerifier(FriendStore(legacyDir));
    });

    tearDown(() => legacyDir.deleteSync(recursive: true));

    test('verifies a signed request exactly as before, reporting the '
        "friend's nodeId as their account id", () async {
      final verification = await verifySignedBy(alice, using: legacyVerifier);

      expect(verification.result, RequestVerificationResult.valid);
      expect(verification.friendAccountId, alice.nodeId);
      expect(verification.deviceNodeId, alice.nodeId);
    });

    test('still rejects a stranger', () async {
      final verification = await verifySignedBy(bob, using: legacyVerifier);
      expect(verification.result, RequestVerificationResult.unknownNode);
    });
  });

  group('an account-based friend with two linked devices', () {
    late Directory phoneDir;
    late Directory desktopDir;
    late Directory strangerDir;
    late NodeIdentity phone;
    late NodeIdentity desktop;
    late NodeIdentity stranger;

    setUp(() async {
      phoneDir = Directory.systemTemp.createTempSync('musicat_signing_phone_');
      desktopDir = Directory.systemTemp.createTempSync('musicat_signing_desk_');
      strangerDir = Directory.systemTemp.createTempSync(
        'musicat_signing_stranger_',
      );
      phone = await NodeIdentityStore(phoneDir).loadOrCreate();
      desktop = await NodeIdentityStore(desktopDir).loadOrCreate();
      stranger = await NodeIdentityStore(strangerDir).loadOrCreate();

      await bobsFriends.add(
        Friend(
          accountId: 'account-carol',
          devices: [
            FriendDevice(
              nodeId: phone.nodeId,
              publicKeyBase64: await phone.publicKeyBase64(),
              address: 'phone.example:8080',
            ),
            FriendDevice(
              nodeId: desktop.nodeId,
              publicKeyBase64: await desktop.publicKeyBase64(),
              address: 'desktop.example:8080',
            ),
          ],
          displayName: 'Carol',
        ),
      );
    });

    tearDown(() {
      phoneDir.deleteSync(recursive: true);
      desktopDir.deleteSync(recursive: true);
      strangerDir.deleteSync(recursive: true);
    });

    test('a request from either device verifies as the same account', () async {
      final fromPhone = await verifySignedBy(phone);
      final fromDesktop = await verifySignedBy(desktop);

      expect(fromPhone.result, RequestVerificationResult.valid);
      expect(fromPhone.friendAccountId, 'account-carol');
      expect(fromPhone.deviceNodeId, phone.nodeId);

      expect(fromDesktop.result, RequestVerificationResult.valid);
      expect(fromDesktop.friendAccountId, 'account-carol');
      expect(fromDesktop.deviceNodeId, desktop.nodeId);
    });

    test('a third, unlinked device is rejected', () async {
      final verification = await verifySignedBy(stranger);

      expect(verification.result, RequestVerificationResult.unknownNode);
      expect(verification.friendAccountId, isNull);
    });

    test("a device signing with another linked device's nodeId is rejected "
        '(the key, not the claimed id, is what has to match)', () async {
      final headers = await RequestSigner(
        stranger,
      ).sign(method: 'GET', path: '/api/v1/federation/ping');

      final verification = await verifier.verify(
        method: 'GET',
        path: '/api/v1/federation/ping',
        body: '',
        nodeId: phone.nodeId, // claims to be the phone
        timestamp: headers['X-Timestamp'],
        signatureBase64: headers['X-Signature'],
      );

      expect(verification.result, RequestVerificationResult.invalidSignature);
    });

    test('unlinking a device locally stops it verifying, while the other '
        'device keeps working', () async {
      await bobsFriends.updateDevices('account-carol', [
        FriendDevice(
          nodeId: desktop.nodeId,
          publicKeyBase64: await desktop.publicKeyBase64(),
          address: 'desktop.example:8080',
        ),
      ]);

      expect(
        (await verifySignedBy(phone)).result,
        RequestVerificationResult.unknownNode,
      );
      expect(
        (await verifySignedBy(desktop)).result,
        RequestVerificationResult.valid,
      );
    });

    test('an account with no devices left verifies nothing', () async {
      await bobsFriends.updateDevices('account-carol', []);

      expect(
        (await verifySignedBy(phone)).result,
        RequestVerificationResult.unknownNode,
      );
    });
  });

  group('the offline rule: the resolver is only ever a cache-miss path', () {
    late _RecordingResolver resolver;
    late RequestVerifier resolvingVerifier;

    setUp(() {
      resolver = _RecordingResolver();
      resolvingVerifier = RequestVerifier(
        bobsFriends,
        unknownDeviceResolver: resolver,
      );
    });

    test(
      'an established friend verifies without consulting it at all',
      () async {
        final verification = await verifySignedBy(
          alice,
          using: resolvingVerifier,
        );

        expect(verification.result, RequestVerificationResult.valid);
        expect(resolver.calls, isEmpty);
      },
    );

    test('a bad signature from an established friend does not consult it '
        'either', () async {
      final verification = await verifySignedBy(
        alice,
        using: resolvingVerifier,
        verifyPath: '/somewhere/else',
      );

      expect(verification.result, RequestVerificationResult.invalidSignature);
      expect(resolver.calls, isEmpty);
    });

    test('an unknown nodeId consults it exactly once, and is still rejected '
        'when nothing was learned', () async {
      final verification = await verifySignedBy(bob, using: resolvingVerifier);

      expect(verification.result, RequestVerificationResult.unknownNode);
      expect(resolver.calls, [bob.nodeId]);
    });

    test('a verifier with no resolver rejects an unknown nodeId without any '
        'way of looking anything up', () async {
      expect(RequestVerifier(bobsFriends).unknownDeviceResolver, isNull);
      final verification = await verifySignedBy(bob);
      expect(verification.result, RequestVerificationResult.unknownNode);
    });
  });
}
