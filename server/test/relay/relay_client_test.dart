import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/relay/relay_client.dart';
import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  late Directory identityDir;
  late NodeIdentity identity;
  late RelayHub hub;
  late HttpServer server;
  late String wsUrl;
  late String httpUrl;
  late RelayClient client;

  setUp(() async {
    identityDir = Directory.systemTemp.createTempSync('musicat_relay_client_');
    identity = await NodeIdentityStore(identityDir).loadOrCreate();
    hub = RelayHub();
    server = await shelf_io.serve(hub.buildRouter().call, 'localhost', 0);
    wsUrl = 'ws://localhost:${server.port}/connect';
    httpUrl = 'http://localhost:${server.port}';
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
    identityDir.deleteSync(recursive: true);
  });

  test('a real request forwarded through the relay reaches the local handler '
      'exactly like a direct one would', () async {
    final localRouter = Router()
      ..get(
        '/api/v1/node',
        (Request request) => Response.ok(
          jsonEncode({'nodeId': identity.nodeId}),
          headers: {'content-type': 'application/json'},
        ),
      );
    client = RelayClient(identity: identity, localHandler: localRouter.call);

    final connected = await client.connect(wsUrl);
    expect(connected, isTrue);
    expect(client.isConnected, isTrue);
    expect(hub.isConnected(identity.nodeId), isTrue);

    final response = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );

    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'nodeId': identity.nodeId});
  });

  test("the local handler's own object-level authz still applies -- the relay "
      'never bypasses it', () async {
    final localRouter = Router()
      ..get(
        '/protected',
        (Request request) => request.headers['x-secret'] == 'right'
            ? Response.ok('ok')
            : Response(403),
      );
    client = RelayClient(identity: identity, localHandler: localRouter.call);
    await client.connect(wsUrl);

    final denied = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/protected'),
    );
    expect(denied.statusCode, 403);

    final allowed = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/protected'),
      headers: {'x-secret': 'right'},
    );
    expect(allowed.statusCode, 200);
  });

  test('forwards POST bodies intact', () async {
    final localRouter = Router()
      ..post('/echo', (Request request) async {
        final body = await request.readAsString();
        return Response.ok(body);
      });
    client = RelayClient(identity: identity, localHandler: localRouter.call);
    await client.connect(wsUrl);

    final response = await http.post(
      Uri.parse('$httpUrl/${identity.nodeId}/echo'),
      body: 'hello from the other side',
    );
    expect(response.statusCode, 200);
    expect(response.body, 'hello from the other side');
  });

  test(
    'connect() returns false, not an exception, for an unreachable relay',
    () async {
      client = RelayClient(
        identity: identity,
        localHandler: (request) async => Response.ok('unused'),
      );
      final connected = await client.connect('ws://localhost:1/connect');
      expect(connected, isFalse);
      expect(client.isConnected, isFalse);
    },
  );

  test('close() disconnects and the hub stops routing to it', () async {
    final localRouter = Router()
      ..get('/api/v1/node', (Request request) => Response.ok('ok'));
    client = RelayClient(identity: identity, localHandler: localRouter.call);
    await client.connect(wsUrl);
    expect(hub.isConnected(identity.nodeId), isTrue);

    await client.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hub.isConnected(identity.nodeId), isFalse);

    final response = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );
    expect(response.statusCode, 502);
  });

  test('a previously-successful connection reconnects automatically after the '
      'tunnel drops, with no external call telling it to', () async {
    final localRouter = Router()
      ..get(
        '/api/v1/node',
        (Request request) => Response.ok(
          jsonEncode({'nodeId': identity.nodeId}),
          headers: {'content-type': 'application/json'},
        ),
      );
    // A tiny backoff so this test doesn't wait out the real 5s/300s
    // production defaults.
    client = RelayClient(
      identity: identity,
      localHandler: localRouter.call,
      initialReconnectDelay: const Duration(milliseconds: 50),
      maxReconnectDelay: const Duration(milliseconds: 200),
    );

    expect(await client.connect(wsUrl), isTrue);
    expect(hub.isConnected(identity.nodeId), isTrue);

    // Simulate the tunnel dropping (a network blip, or the relay kicking
    // this connection) from the relay side -- deliberately *not* by
    // closing the listening `server`: once a connection is upgraded to a
    // WebSocket it's hijacked away from the `HttpServer` entirely (real
    // `dart:io`/`shelf` behavior), so even `server.close(force: true)`
    // would leave this specific tunnel running and the test would never
    // see a drop at all. `hub.disconnect` severs the real underlying
    // socket while the relay's own listening endpoint (and `wsUrl`) stays
    // up throughout, exactly like a transient blip would.
    await hub.disconnect(identity.nodeId);
    expect(hub.isConnected(identity.nodeId), isFalse);

    // Nothing external calls connect()/reconnect() again -- RelayClient
    // must notice the drop and re-establish the tunnel on its own.
    await _waitUntil(
      () => hub.isConnected(identity.nodeId),
      timeout: const Duration(seconds: 5),
    );
    expect(client.isConnected, isTrue);

    final response = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'nodeId': identity.nodeId});
  });

  test('close() cancels a pending scheduled reconnect -- it does not '
      'resurrect the tunnel after an intentional shutdown', () async {
    final localRouter = Router()
      ..get('/api/v1/node', (Request request) => Response.ok('ok'));
    client = RelayClient(
      identity: identity,
      localHandler: localRouter.call,
      initialReconnectDelay: const Duration(milliseconds: 300),
      maxReconnectDelay: const Duration(milliseconds: 500),
    );

    expect(await client.connect(wsUrl), isTrue);

    // Drop the tunnel (schedules a reconnect ~300ms out), then close()
    // well before that reconnect timer would fire. The relay itself stays
    // up throughout -- if close() failed to cancel the pending timer, the
    // client would have no trouble tunneling right back in, so this
    // genuinely tests the cancellation, not mere unreachability.
    await hub.disconnect(identity.nodeId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await client.close();

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(client.isConnected, isFalse);
    expect(hub.isConnected(identity.nodeId), isFalse);
  });

  test('a fresh connect() while a reconnect is scheduled wins the race -- '
      'the stale timer never clobbers or duplicates the new connection '
      '(regression test for issue #3)', () async {
    final localRouter = Router()
      ..get('/api/v1/node', (Request request) => Response.ok('ok'));
    client = RelayClient(
      identity: identity,
      localHandler: localRouter.call,
      initialReconnectDelay: const Duration(milliseconds: 200),
      maxReconnectDelay: const Duration(milliseconds: 400),
    );

    expect(await client.connect(wsUrl), isTrue);
    expect(hub.connectedCount, 1);

    // Drop the tunnel from the relay side -- this schedules a reconnect
    // ~200ms out (see _scheduleReconnect).
    await hub.disconnect(identity.nodeId);
    expect(hub.connectedCount, 0);

    // Before that stale timer fires, something else (e.g. a caller
    // reacting to "network restored") calls connect() again directly.
    // Without the fix, connect() never cancels the pending timer, so it
    // stays armed in parallel with this new, legitimate connection.
    expect(await client.connect(wsUrl), isTrue);
    expect(hub.connectedCount, 1);

    // Wait well past when the stale timer would have fired if it hadn't
    // been invalidated. If issue #3's bug were still present, the timer
    // would fire here, see a non-null _relayUrl (now pointing at the
    // *new* connection's URL), and either silently orphan the new
    // connection (by assigning its own new channel over it) or open a
    // second, redundant tunnel alongside it.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(hub.connectedCount, 1);
    expect(client.isConnected, isTrue);

    // The one connection that's actually live must still work end to end.
    final response = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );
    expect(response.statusCode, 200);
  });

  test('keeps quietly retrying with backoff -- never crashes and never '
      'falsely reports itself connected -- while the relay stays down for '
      'good', () async {
    final localRouter = Router()
      ..get('/api/v1/node', (Request request) => Response.ok('ok'));
    client = RelayClient(
      identity: identity,
      localHandler: localRouter.call,
      initialReconnectDelay: const Duration(milliseconds: 30),
      maxReconnectDelay: const Duration(milliseconds: 60),
    );

    expect(await client.connect(wsUrl), isTrue);

    // Sever the current tunnel *and* take the relay's listening endpoint
    // down for good this time, so every subsequent retry attempt fails
    // outright (connection refused) rather than succeeding again.
    await hub.disconnect(identity.nodeId);
    await server.close(force: true);

    // Several retry cycles' worth of real time: with a real (non-empty)
    // set of network interfaces in this test environment, each tick
    // actually attempts a doomed connection, hits `_attemptConnect`'s own
    // `catch (_)`, and reschedules -- this exercises exactly the code
    // path the "no network interface" skip sits next to, just via the
    // "network present but relay unreachable" branch instead. It must
    // never throw out of the test isolate and must never flip
    // `isConnected` to true.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(client.isConnected, isFalse);
  });

  group('claimUsername', () {
    test('a successful claim round-trips through a real hub', () async {
      client = RelayClient(
        identity: identity,
        localHandler: (request) async => Response.ok('unused'),
      );
      expect(await client.connect(wsUrl), isTrue);

      final result = await client.claimUsername('alice');

      expect(result.success, isTrue);
      expect(result.error, isNull);
      expect(await hub.usernames.lookup('alice'), identity.nodeId);
    });

    test('a rejected claim (already taken by a different node) surfaces the '
        "hub's error", () async {
      final otherIdentityDir = Directory.systemTemp.createTempSync(
        'musicat_relay_client_other_',
      );
      addTearDown(() => otherIdentityDir.deleteSync(recursive: true));
      final otherIdentity = await NodeIdentityStore(
        otherIdentityDir,
      ).loadOrCreate();
      await hub.usernames.claim('alice', otherIdentity.nodeId);

      client = RelayClient(
        identity: identity,
        localHandler: (request) async => Response.ok('unused'),
      );
      expect(await client.connect(wsUrl), isTrue);

      final result = await client.claimUsername('alice');

      expect(result.success, isFalse);
      expect(result.error, 'Username already taken');
    });

    test('returns a clear failure result, not a thrown exception, when not '
        'currently connected', () async {
      client = RelayClient(
        identity: identity,
        localHandler: (request) async => Response.ok('unused'),
      );

      final result = await client.claimUsername('alice');

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
    });

    test('a claim in flight when the tunnel drops fails promptly, and a '
        'subsequent claim on the reconnected tunnel succeeds right away '
        '(regression test for issue #9)', () async {
      client = RelayClient(
        identity: identity,
        localHandler: (request) async => Response.ok('unused'),
        initialReconnectDelay: const Duration(milliseconds: 50),
        maxReconnectDelay: const Duration(milliseconds: 200),
      );
      expect(await client.connect(wsUrl), isTrue);

      // Fire the claim, then sever the tunnel from the hub side without
      // ever awaiting in between -- claimUsername()'s own synchronous
      // prefix (setting _pendingClaim, writing the message to the socket)
      // and hub.disconnect()'s own synchronous prefix (removing the
      // tunnel) both run to completion before either yields to the event
      // loop, so the drop is guaranteed to land while this claim is still
      // genuinely in flight, exactly like a real network blip mid-claim.
      final claimFuture = client.claimUsername('mid-flight');
      await hub.disconnect(identity.nodeId);

      final stopwatch = Stopwatch()..start();
      final result = await claimFuture;
      stopwatch.stop();

      expect(result.success, isFalse);
      expect(result.error, 'Connection to the relay was lost, try again');
      // The crux of the regression: without the fix, nothing completes
      // _pendingClaim on a drop, so this sits until claimUsername()'s own
      // hardcoded 10-second internal timeout finally fires. With the fix,
      // it fails as soon as _serve()'s cleanup runs -- well under a
      // second on a local loopback connection.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));

      // The automatic reconnect (ADR 0036) should re-establish a healthy
      // tunnel shortly after.
      await _waitUntil(
        () => hub.isConnected(identity.nodeId),
        timeout: const Duration(seconds: 5),
      );
      expect(client.isConnected, isTrue);

      // A fresh claim on the now-healthy tunnel must succeed immediately --
      // not get rejected with "Another username claim is already in
      // progress" because of a stale _pendingClaim left over from the
      // dropped one.
      final freshResult = await client.claimUsername('mid-flight');
      expect(freshResult.success, isTrue);
      expect(freshResult.error, isNull);
      expect(await hub.usernames.lookup('mid-flight'), identity.nodeId);
    });
  });
}

/// Polls [condition] until it's true or [timeout] elapses, without relying
/// on any fixed sleep -- the reconnect under test is driven by real
/// `Timer`s, so this only ever waits as long as it actually needs to.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration pollInterval = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition not met within $timeout');
    }
    await Future<void>.delayed(pollInterval);
  }
}
