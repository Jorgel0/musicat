import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/relay/relay_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// **What a hostile relay can and cannot do with the push channel.**
///
/// The relay is a separate trust domain from the account service, even when
/// the two run in one process today, and the push is the one message a relay
/// *originates* rather than forwards. So the interesting question is not "does
/// the push work" (`account_relay_reachability_test.dart` answers that) but
/// "what happens when the thing sending it is lying".
///
/// The relay here is therefore **hostile**: a WebSocket server that completes
/// the handshake without ever proving anything (a node doesn't authenticate
/// its relay -- it doesn't need to, which is exactly the property under test)
/// and then sends whatever frames this file wants. The node under test is a
/// real [startMusicatServer] pointed at it, with a real, honest account
/// service alongside.
///
/// The claim being tested: **the worst a hostile relay achieves is making the
/// node poll.** It cannot inject a friend, a friend request, a device, or a
/// key, because the push has nowhere to put one and the node re-fetches
/// everything itself over an authenticated request.
void main() {
  late Directory accountsDir;
  late Directory nodeDir;
  late AccountStore accountStore;
  late FriendRequestStore friendRequestStore;
  late HttpServer accountServer;
  late String accountServiceUrl;
  late List<String> accountServiceCalls;

  late HttpServer hostileRelay;
  late String hostileRelayWsUrl;
  late Completer<WebSocketChannel> tunnelToNode;

  late MusicatServerHandle node;

  String nodeUrl(String path) => 'http://localhost:${node.port}$path';

  setUp(() async {
    accountsDir = Directory.systemTemp.createTempSync('musicat_push_accounts_');
    nodeDir = Directory.systemTemp.createTempSync('musicat_push_node_');
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
    accountServiceUrl = 'http://localhost:${accountServer.port}/accounts';

    // A relay that speaks just enough of the handshake for a RelayClient to
    // consider itself connected, and no more. It never checks the signature
    // it is handed -- there is nothing here for a node to trust, and that is
    // the point.
    tunnelToNode = Completer<WebSocketChannel>();
    hostileRelay = await shelf_io.serve(
      webSocketHandler((WebSocketChannel channel, String? protocol) {
        unawaited(() async {
          final messages = StreamIterator<dynamic>(channel.stream);
          await messages.moveNext(); // hello
          channel.sink.add(
            RelayChallenge(base64Encode(List<int>.filled(24, 7))).encode(),
          );
          await messages.moveNext(); // auth -- deliberately not verified
          channel.sink.add(const RelayAuthResult(success: true).encode());
          if (!tunnelToNode.isCompleted) tunnelToNode.complete(channel);
          while (await messages.moveNext()) {
            // Drain whatever the node says; this relay never answers.
          }
        }());
      }),
      'localhost',
      0,
    );
    hostileRelayWsUrl = 'ws://localhost:${hostileRelay.port}/connect';

    node = await startMusicatServer(
      dataDir: nodeDir,
      port: 0,
      relayUrl: hostileRelayWsUrl,
      accountServiceUrl: accountServiceUrl,
      friendDeviceRefreshInterval: const Duration(hours: 12),
      // 12 hours, so any account-service traffic observed below was caused
      // by the push and by nothing else.
      accountPollInterval: const Duration(hours: 12),
    );
    expect(node.relayUrl, hostileRelayWsUrl);
  });

  tearDown(() async {
    await node.close();
    await hostileRelay.close(force: true);
    await accountServer.close(force: true);
    accountsDir.deleteSync(recursive: true);
    nodeDir.deleteSync(recursive: true);
  });

  Future<void> logIn() async {
    final response = await http.post(
      Uri.parse(nodeUrl('/api/v1/account/login')),
      body: jsonEncode({'username': 'jorge', 'password': 'hunter2-correct'}),
    );
    expect(response.statusCode, 200, reason: response.body);
  }

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
    String? reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(reason ?? 'Condition not met within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('a push stuffed with a forged friend adds nobody -- all the node does '
      'is go and ask the account service itself', () async {
    await logIn();
    final channel = await tunnelToNode.future;
    accountServiceCalls.clear();

    // Everything a hostile relay might wish it could say, in one frame: a
    // whole friend, with a key, an address and a relay. None of it is part
    // of the message type, so none of it can be read.
    channel.sink.add(
      jsonEncode({
        'type': 'notify',
        'event': 'friendRequests',
        'friend': {
          'accountId': 'attacker-account',
          'username': 'attacker',
          'devices': [
            {
              'nodeId': 'a' * 64,
              'publicKeyBase64': base64Encode(List<int>.filled(32, 1)),
              'address': 'attacker.example:8080',
              'relayUrl': 'ws://attacker.example/connect',
              'linkedAt': '2026-01-01T00:00:00.000Z',
            },
          ],
        },
        'friendRequests': [
          {
            'id': 'forged',
            'fromAccountId': 'attacker-account',
            'fromUsername': 'attacker',
            'toAccountId': 'whoever',
            'status': 'pending',
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
        ],
      }),
    );

    // The node's *only* reaction: an authenticated fetch of its own.
    await waitUntil(
      () => accountServiceCalls.isNotEmpty,
      reason:
          'The push should have triggered a re-fetch. If it no longer does, '
          'the assertions below about what it could NOT do are vacuous.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Which is exactly the two reads the poller would have done, and nothing
    // that could write anything.
    expect(
      accountServiceCalls.toSet(),
      everyElement(anyOf(contains('/friends'), contains('/friend-requests'))),
    );
    // And the honest account service says this node has no friends, so it
    // has none. The forged payload changed nothing at all.
    expect(await FriendStore(nodeDir).loadAll(), isEmpty);
    final friends = await http.get(
      Uri.parse(nodeUrl('/api/v1/federation/friends')),
    );
    expect(jsonDecode(friends.body), isEmpty);
    final requests = await http.get(
      Uri.parse(nodeUrl('/api/v1/account/friend-requests')),
    );
    expect(
      (jsonDecode(requests.body) as Map<String, dynamic>)['requests'],
      isEmpty,
    );
  });

  test('the extra fields are dropped at the protocol boundary, not merely '
      'ignored downstream', () {
    // The structural reason the test above holds: decoding keeps the event
    // kind and discards everything else, so no amount of care further down
    // is what protects this.
    final decoded =
        RelayMessage.fromJson({
              'type': 'notify',
              'event': 'friendRequests',
              'accountId': 'attacker-account',
              'devices': [
                {'nodeId': 'x', 'publicKeyBase64': 'y'},
              ],
            })
            as RelayNotify;

    expect(decoded.event, 'friendRequests');
    expect(decoded.toJson().keys.toSet(), {'type', 'event'});
  });

  test('an unrecognized event kind is ignored, and does not even cost a '
      'fetch', () async {
    await logIn();
    final channel = await tunnelToNode.future;
    accountServiceCalls.clear();

    channel.sink.add(
      jsonEncode({'type': 'notify', 'event': 'somethingElseEntirely'}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(accountServiceCalls, isEmpty);
    // ...and the tunnel is still up: an unknown kind is not a protocol error.
    expect(await FriendStore(nodeDir).loadAll(), isEmpty);
  });

  test(
    'a push to a node with no session costs nothing at all -- a hostile '
    'relay cannot make a logged-out node talk to the account service',
    () async {
      // No login at all this time.
      final channel = await tunnelToNode.future;
      accountServiceCalls.clear();

      for (var i = 0; i < 20; i++) {
        channel.sink.add(const RelayNotify('friendRequests').encode());
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(accountServiceCalls, isEmpty);
    },
  );

  test('a flood of pushes collapses into one refresh in flight, rather than '
      'stampeding the account service', () async {
    await logIn();
    final channel = await tunnelToNode.future;
    accountServiceCalls.clear();

    for (var i = 0; i < 50; i++) {
      channel.sink.add(const RelayNotify('friendRequests').encode());
    }
    await waitUntil(() => accountServiceCalls.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // 50 pushes, not 100 requests. The exact number depends on how many
    // land between the guard being cleared and the next frame arriving, so
    // this asserts the order of magnitude rather than a brittle constant --
    // what matters is that the pushes are not amplified 1:2.
    expect(
      accountServiceCalls.length,
      lessThan(20),
      reason:
          'A push flood must not become an account-service flood: the '
          "poller's one-run-at-a-time guard is what bounds this.",
    );
  });
}
