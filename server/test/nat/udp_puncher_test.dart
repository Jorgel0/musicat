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

  Future<void> mutuallyTrust() async {
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
  }

  test('two mutually-trusting friends punch through to each other', () async {
    await mutuallyTrust();

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

  group('isConnected / lastSeen', () {
    test('are unset until a valid packet arrives', () {
      expect(alicePuncher.isConnected(bob.nodeId), isFalse);
      expect(alicePuncher.lastSeen(bob.nodeId), isNull);
    });

    test('become true/recent right after a successful punch', () async {
      await mutuallyTrust();

      await Future.wait([
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

      expect(alicePuncher.isConnected(bob.nodeId), isTrue);
      expect(
        alicePuncher.lastSeen(bob.nodeId),
        closeToTime(DateTime.now(), const Duration(seconds: 1)),
      );
    });
  });

  group('startKeepalive / stopKeepalive', () {
    test(
      'keeps isConnected true well past a single punch alone would',
      () async {
        await mutuallyTrust();

        // A one-shot punch (no keepalive) whose "connected" window is short.
        await Future.wait([
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

        bobPuncher.startKeepalive(
          nodeId: alice.nodeId,
          host: '127.0.0.1',
          port: alicePuncher.localPort!,
          interval: const Duration(milliseconds: 100),
        );

        // Long enough that a one-shot punch's mapping would read as stale
        // under a short `within`, but short keepalive packets keep refreshing
        // it in the meantime.
        await Future<void>.delayed(const Duration(milliseconds: 700));

        expect(
          alicePuncher.isConnected(
            bob.nodeId,
            within: const Duration(milliseconds: 300),
          ),
          isTrue,
        );
      },
    );

    test('stopKeepalive lets the connection go stale again', () async {
      await mutuallyTrust();
      await Future.wait([
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

      bobPuncher.startKeepalive(
        nodeId: alice.nodeId,
        host: '127.0.0.1',
        port: alicePuncher.localPort!,
        interval: const Duration(milliseconds: 100),
      );
      // startKeepalive's timer registration happens after an async address
      // lookup, so give it a moment to actually take effect before either
      // asserting on it or racing a stop against it.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bobPuncher.isMaintaining(alice.nodeId), isTrue);

      bobPuncher.stopKeepalive(alice.nodeId);
      expect(bobPuncher.isMaintaining(alice.nodeId), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        alicePuncher.isConnected(
          bob.nodeId,
          within: const Duration(milliseconds: 300),
        ),
        isFalse,
      );
    });
  });

  group('punchAndMaintain', () {
    test('starts a keepalive automatically on success', () async {
      await mutuallyTrust();

      final results = await Future.wait([
        alicePuncher.punchAndMaintain(
          nodeId: bob.nodeId,
          host: '127.0.0.1',
          port: bobPuncher.localPort!,
          punchDuration: const Duration(seconds: 2),
          keepaliveInterval: const Duration(milliseconds: 100),
        ),
        bobPuncher.punch(
          host: '127.0.0.1',
          port: alicePuncher.localPort!,
          duration: const Duration(seconds: 2),
          interval: const Duration(milliseconds: 100),
        ),
      ]);

      expect(results[0], isTrue);
      // startKeepalive's timer registration happens after an async address
      // lookup that punchAndMaintain doesn't wait on — give it a moment.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alicePuncher.isMaintaining(bob.nodeId), isTrue);
    });

    test(
      'keeps sending keepalives even when the initial punch heard nothing back',
      () async {
        // No mutual trust set up -- the punch can't succeed at hearing
        // back, but it should still arm an ongoing keepalive: this
        // node's own outbound packets are what keep *its* NAT mapping
        // open for the peer, independent of whether it has confirmed the
        // reverse direction (see punchAndMaintain's doc comment for the
        // real bug this used to be).
        final heardBack = await alicePuncher.punchAndMaintain(
          nodeId: bob.nodeId,
          host: '127.0.0.1',
          port: bobPuncher.localPort!,
          punchDuration: const Duration(milliseconds: 300),
        );

        expect(heardBack, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(alicePuncher.isMaintaining(bob.nodeId), isTrue);
      },
    );
  });
}

/// A small local matcher: within [tolerance] of [expected].
Matcher closeToTime(DateTime expected, Duration tolerance) =>
    predicate<DateTime>(
      (actual) => actual.difference(expected).abs() <= tolerance,
      'within $tolerance of $expected',
    );
