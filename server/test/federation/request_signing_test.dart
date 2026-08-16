import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:test/test.dart';

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
      Friend(
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

  test('a request signed by a known friend verifies as valid', () async {
    final headers = await RequestSigner(
      alice,
    ).sign(method: 'GET', path: '/api/v1/federation/ping');

    final result = await verifier.verify(
      method: 'GET',
      path: '/api/v1/federation/ping',
      body: '',
      nodeId: headers['X-Node-Id'],
      timestamp: headers['X-Timestamp'],
      signatureBase64: headers['X-Signature'],
    );

    expect(result, RequestVerificationResult.valid);
  });

  test('rejects a request from a node that is not a friend', () async {
    final headers = await RequestSigner(
      bob,
    ).sign(method: 'GET', path: '/api/v1/federation/ping');

    final result = await verifier.verify(
      method: 'GET',
      path: '/api/v1/federation/ping',
      body: '',
      nodeId: headers['X-Node-Id'],
      timestamp: headers['X-Timestamp'],
      signatureBase64: headers['X-Signature'],
    );

    expect(result, RequestVerificationResult.unknownNode);
  });

  test('rejects a tampered path (signature no longer matches)', () async {
    final headers = await RequestSigner(
      alice,
    ).sign(method: 'GET', path: '/api/v1/federation/ping');

    final result = await verifier.verify(
      method: 'GET',
      path: '/api/v1/federation/friends', // different from what was signed
      body: '',
      nodeId: headers['X-Node-Id'],
      timestamp: headers['X-Timestamp'],
      signatureBase64: headers['X-Signature'],
    );

    expect(result, RequestVerificationResult.invalidSignature);
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

    final result = await verifier.verify(
      method: 'GET',
      path: '/api/v1/federation/ping',
      body: '',
      nodeId: alice.nodeId,
      timestamp: staleTimestamp,
      signatureBase64: signatureBase64,
    );

    expect(result, RequestVerificationResult.staleTimestamp);
  });

  test(
    'revoking a friend makes their previously-valid signature fail',
    () async {
      final headers = await RequestSigner(
        alice,
      ).sign(method: 'GET', path: '/api/v1/federation/ping');

      await bobsFriends.remove(alice.nodeId);

      final result = await verifier.verify(
        method: 'GET',
        path: '/api/v1/federation/ping',
        body: '',
        nodeId: headers['X-Node-Id'],
        timestamp: headers['X-Timestamp'],
        signatureBase64: headers['X-Signature'],
      );

      expect(result, RequestVerificationResult.unknownNode);
    },
  );
}
