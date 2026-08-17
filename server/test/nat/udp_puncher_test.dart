import 'dart:io';

import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/nat/udp_puncher.dart';
import 'package:test/test.dart';

void main() {
  late Directory aliceDir;
  late Directory bobDir;
  late NodeIdentity alice;
  late NodeIdentity bob;
  late UdpPuncher alicePuncher;
  late UdpPuncher bobPuncher;

  setUp(() async {
    aliceDir = Directory.systemTemp.createTempSync('musicat_punch_alice_');
    bobDir = Directory.systemTemp.createTempSync('musicat_punch_bob_');
    alice = await NodeIdentityStore(aliceDir).loadOrCreate();
    bob = await NodeIdentityStore(bobDir).loadOrCreate();

    alicePuncher = UdpPuncher(
      identity: alice,
      friendStore: FriendStore(aliceDir),
    );
    bobPuncher = UdpPuncher(identity: bob, friendStore: FriendStore(bobDir));
    await alicePuncher.bind();
    await bobPuncher.bind();
  });

  tearDown(() async {
    await alicePuncher.close();
    await bobPuncher.close();
    aliceDir.deleteSync(recursive: true);
    bobDir.deleteSync(recursive: true);
  });

  test('two mutually-trusting friends punch through to each other', () async {
    await FriendStore(aliceDir).add(
      Friend(
        nodeId: bob.nodeId,
        publicKeyBase64: await bob.publicKeyBase64(),
        address: '127.0.0.1:0',
      ),
    );
    await FriendStore(bobDir).add(
      Friend(
        nodeId: alice.nodeId,
        publicKeyBase64: await alice.publicKeyBase64(),
        address: '127.0.0.1:0',
      ),
    );

    final results = await Future.wait([
      alicePuncher.punch(
        host: '127.0.0.1',
        port: bobPuncher.localPort!,
        duration: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 100),
      ),
      bobPuncher.punch(
        host: '127.0.0.1',
        port: alicePuncher.localPort!,
        duration: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 100),
      ),
    ]);

    expect(results[0], bob.nodeId); // what Alice's punch received
    expect(results[1], alice.nodeId); // what Bob's punch received
  });

  test('a punch from a node that is not a trusted friend is ignored', () async {
    // Neither side trusts the other -- Bob's incoming packets from Alice
    // should be rejected, and vice versa, so both time out.
    final results = await Future.wait([
      alicePuncher.punch(
        host: '127.0.0.1',
        port: bobPuncher.localPort!,
        duration: const Duration(milliseconds: 500),
        interval: const Duration(milliseconds: 100),
      ),
      bobPuncher.punch(
        host: '127.0.0.1',
        port: alicePuncher.localPort!,
        duration: const Duration(milliseconds: 500),
        interval: const Duration(milliseconds: 100),
      ),
    ]);

    expect(results[0], isNull);
    expect(results[1], isNull);
  });

  test('punch throws if bind() was never called', () async {
    final unbound = UdpPuncher(
      identity: alice,
      friendStore: FriendStore(aliceDir),
    );
    expect(
      () => unbound.punch(host: '127.0.0.1', port: 1234),
      throwsStateError,
    );
  });
}
