import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:musicat_server/src/relay/relay_protocol.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late Directory identityDir;
  late NodeIdentity identity;
  late RelayHub hub;
  late HttpServer server;
  late String wsUrl;
  late String httpUrl;

  setUp(() async {
    identityDir = Directory.systemTemp.createTempSync('musicat_relay_hub_');
    identity = await NodeIdentityStore(identityDir).loadOrCreate();
    hub = RelayHub(requestTimeout: const Duration(seconds: 2));
    server = await shelf_io.serve(hub.buildRouter().call, 'localhost', 0);
    wsUrl = 'ws://localhost:${server.port}/connect';
    httpUrl = 'http://localhost:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    identityDir.deleteSync(recursive: true);
  });

  // Returns the still-live StreamIterator alongside the channel -- the
  // underlying stream is single-subscription, so a caller that needs to
  // keep reading after the handshake (e.g. to act as the "other side"
  // answering a forwarded request) must reuse this same iterator rather
  // than starting a fresh one on the same stream.
  Future<(WebSocketChannel, StreamIterator<dynamic>)> authenticate(
    NodeIdentity id,
  ) async {
    final channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
    final messages = StreamIterator<dynamic>(channel.stream);
    final publicKey = await id.publicKeyBase64();
    channel.sink.add(
      RelayHello(nodeId: id.nodeId, publicKeyBase64: publicKey).encode(),
    );
    await messages.moveNext();
    final challenge =
        RelayMessage.decode(messages.current as String) as RelayChallenge;
    final signature = await Ed25519().sign(
      base64Decode(challenge.nonceBase64),
      keyPair: id.keyPair,
    );
    channel.sink.add(RelayAuth(base64Encode(signature.bytes)).encode());
    await messages.moveNext();
    final result =
        RelayMessage.decode(messages.current as String) as RelayAuthResult;
    if (!result.success) throw StateError('auth failed: ${result.error}');
    return (channel, messages);
  }

  test('authenticates a real identity and registers its tunnel', () async {
    final (channel, _) = await authenticate(identity);
    expect(hub.isConnected(identity.nodeId), isTrue);
    await channel.sink.close();
  });

  test('rejects a nodeId that does not match the public key', () async {
    final channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
    final messages = StreamIterator<dynamic>(channel.stream);
    final publicKey = await identity.publicKeyBase64();
    channel.sink.add(
      RelayHello(
        nodeId: 'not-the-real-fingerprint',
        publicKeyBase64: publicKey,
      ).encode(),
    );
    await messages.moveNext();
    final result =
        RelayMessage.decode(messages.current as String) as RelayAuthResult;
    expect(result.success, isFalse);
    expect(hub.isConnected('not-the-real-fingerprint'), isFalse);
  });

  test('rejects an invalid signature over the challenge', () async {
    final channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
    final messages = StreamIterator<dynamic>(channel.stream);
    final publicKey = await identity.publicKeyBase64();
    channel.sink.add(
      RelayHello(nodeId: identity.nodeId, publicKeyBase64: publicKey).encode(),
    );
    await messages.moveNext(); // challenge, ignored
    channel.sink.add(RelayAuth(base64Encode(List.filled(64, 7))).encode());
    await messages.moveNext();
    final result =
        RelayMessage.decode(messages.current as String) as RelayAuthResult;
    expect(result.success, isFalse);
    expect(hub.isConnected(identity.nodeId), isFalse);
  });

  test('forwarding to an unconnected nodeId returns 502, not a hang', () async {
    final response = await http.get(
      Uri.parse('$httpUrl/some-node-never-connected/api/v1/node'),
    );
    expect(response.statusCode, 502);
  });

  test('forwards a request through the tunnel and returns the reply', () async {
    final (channel, messages) = await authenticate(identity);

    final responderDone = Future(() async {
      await messages.moveNext();
      final request =
          RelayMessage.decode(messages.current as String)
              as RelayRequestMessage;
      expect(request.method, 'GET');
      expect(request.path, '/api/v1/node');
      channel.sink.add(
        RelayResponseMessage(
          requestId: request.requestId,
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          bodyBase64: base64Encode(
            utf8.encode('{"nodeId":"${identity.nodeId}"}'),
          ),
        ).encode(),
      );
    });

    final response = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );
    await responderDone;

    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), {'nodeId': identity.nodeId});
    await channel.sink.close();
  });

  test('times out with 504 if the tunnel never answers', () async {
    final (channel, _) = await authenticate(identity);
    final response = await http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );
    expect(response.statusCode, 504);
    await channel.sink.close();
  });

  test('disconnecting a tunnel mid-request fails the in-flight request '
      'promptly instead of making it wait out the full requestTimeout '
      '(regression test for issue #4)', () async {
    final (channel, messages) = await authenticate(identity);

    // Deliberately never answers the forwarded request from this side --
    // the point of this test is a request still genuinely in flight (the
    // hub still waiting on tunnel.pending) at the moment disconnect()
    // runs.
    final requestReceived = Completer<void>();
    unawaited(
      Future(() async {
        await messages.moveNext();
        RelayMessage.decode(messages.current as String) as RelayRequestMessage;
        requestReceived.complete();
      }),
    );

    final stopwatch = Stopwatch()..start();
    final responseFuture = http.get(
      Uri.parse('$httpUrl/${identity.nodeId}/api/v1/node'),
    );
    await requestReceived.future;

    await hub.disconnect(identity.nodeId);

    final response = await responseFuture;
    stopwatch.stop();

    expect(response.statusCode, 502);
    // This suite's hub has a 2-second requestTimeout (see setUp). A fix
    // that actually completes the pending request the instant disconnect()
    // learns the tunnel is gone should return in a small fraction of that
    // -- not anywhere close to a clean timeout.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));

    await channel.sink.close();
  });

  test('disconnecting the tunnel un-registers the node', () async {
    final (channel, _) = await authenticate(identity);
    expect(hub.isConnected(identity.nodeId), isTrue);
    await channel.sink.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hub.isConnected(identity.nodeId), isFalse);
  });

  group('username directory', () {
    late Directory otherIdentityDir;
    late NodeIdentity otherIdentity;

    setUp(() async {
      otherIdentityDir = Directory.systemTemp.createTempSync(
        'musicat_relay_hub_other_',
      );
      otherIdentity = await NodeIdentityStore(otherIdentityDir).loadOrCreate();
    });

    tearDown(() {
      otherIdentityDir.deleteSync(recursive: true);
    });

    test('a claim over the authenticated channel is reflected by an '
        'unauthenticated GET /directory/lookup', () async {
      final (channel, messages) = await authenticate(identity);

      channel.sink.add(const RelayClaimUsername('alice').encode());
      await messages.moveNext();
      final result =
          RelayMessage.decode(messages.current as String)
              as RelayClaimUsernameResult;
      expect(result.success, isTrue);
      expect(result.error, isNull);

      final response = await http.get(
        Uri.parse('$httpUrl/directory/lookup?username=alice'),
      );
      expect(response.statusCode, 200);
      expect(jsonDecode(response.body), {'nodeId': identity.nodeId});

      await channel.sink.close();
    });

    test('GET /directory/lookup 404s an unclaimed username', () async {
      final response = await http.get(
        Uri.parse('$httpUrl/directory/lookup?username=never-claimed'),
      );
      expect(response.statusCode, 404);
    });

    test('claiming a username already owned by a different nodeId fails with '
        'a clear error', () async {
      final (aliceChannel, aliceMessages) = await authenticate(identity);
      aliceChannel.sink.add(const RelayClaimUsername('alice').encode());
      await aliceMessages.moveNext();

      final (bobChannel, bobMessages) = await authenticate(otherIdentity);
      bobChannel.sink.add(const RelayClaimUsername('alice').encode());
      await bobMessages.moveNext();
      final bobResult =
          RelayMessage.decode(bobMessages.current as String)
              as RelayClaimUsernameResult;

      expect(bobResult.success, isFalse);
      expect(bobResult.error, 'Username already taken');

      await aliceChannel.sink.close();
      await bobChannel.sink.close();
    });

    test('re-claiming your own username is idempotent', () async {
      final (channel, messages) = await authenticate(identity);
      channel.sink.add(const RelayClaimUsername('alice').encode());
      await messages.moveNext();

      channel.sink.add(const RelayClaimUsername('alice').encode());
      await messages.moveNext();
      final result =
          RelayMessage.decode(messages.current as String)
              as RelayClaimUsernameResult;

      expect(result.success, isTrue);
      await channel.sink.close();
    });

    test('claiming a second username releases the first -- a different node '
        'can then claim it', () async {
      final (aliceChannel, aliceMessages) = await authenticate(identity);
      aliceChannel.sink.add(const RelayClaimUsername('alice').encode());
      await aliceMessages.moveNext();
      aliceChannel.sink.add(const RelayClaimUsername('alicia').encode());
      await aliceMessages.moveNext();
      final supersedeResult =
          RelayMessage.decode(aliceMessages.current as String)
              as RelayClaimUsernameResult;
      expect(supersedeResult.success, isTrue);

      final oldLookup = await http.get(
        Uri.parse('$httpUrl/directory/lookup?username=alice'),
      );
      expect(oldLookup.statusCode, 404);

      final (bobChannel, bobMessages) = await authenticate(otherIdentity);
      bobChannel.sink.add(const RelayClaimUsername('alice').encode());
      await bobMessages.moveNext();
      final bobResult =
          RelayMessage.decode(bobMessages.current as String)
              as RelayClaimUsernameResult;
      expect(bobResult.success, isTrue);

      final newLookup = await http.get(
        Uri.parse('$httpUrl/directory/lookup?username=alice'),
      );
      expect(jsonDecode(newLookup.body), {'nodeId': otherIdentity.nodeId});

      await aliceChannel.sink.close();
      await bobChannel.sink.close();
    });

    test('an invalid-format username is rejected over the channel', () async {
      final (channel, messages) = await authenticate(identity);
      channel.sink.add(const RelayClaimUsername('a').encode());
      await messages.moveNext();
      final result =
          RelayMessage.decode(messages.current as String)
              as RelayClaimUsernameResult;

      expect(result.success, isFalse);
      expect(result.error, 'Invalid username format');
      await channel.sink.close();
    });

    test(
      'persists across a fresh RelayHub pointed at the same data directory',
      () async {
        final dataDir = Directory.systemTemp.createTempSync(
          'musicat_relay_hub_data_',
        );
        addTearDown(() => dataDir.deleteSync(recursive: true));

        final persistentHub = RelayHub(dataDir: dataDir);
        final persistentServer = await shelf_io.serve(
          persistentHub.buildRouter().call,
          'localhost',
          0,
        );
        addTearDown(() => persistentServer.close(force: true));

        final channel = IOWebSocketChannel.connect(
          Uri.parse('ws://localhost:${persistentServer.port}/connect'),
        );
        final channelMessages = StreamIterator<dynamic>(channel.stream);
        final publicKey = await identity.publicKeyBase64();
        channel.sink.add(
          RelayHello(
            nodeId: identity.nodeId,
            publicKeyBase64: publicKey,
          ).encode(),
        );
        await channelMessages.moveNext();
        final challenge =
            RelayMessage.decode(channelMessages.current as String)
                as RelayChallenge;
        final signature = await Ed25519().sign(
          base64Decode(challenge.nonceBase64),
          keyPair: identity.keyPair,
        );
        channel.sink.add(RelayAuth(base64Encode(signature.bytes)).encode());
        await channelMessages.moveNext(); // authResult, ignored

        channel.sink.add(const RelayClaimUsername('alice').encode());
        await channelMessages.moveNext(); // claim result, ignored
        await channel.sink.close();

        final reloadedHub = RelayHub(dataDir: dataDir);
        expect(await reloadedHub.usernames.lookup('alice'), identity.nodeId);
      },
    );
  });
}
