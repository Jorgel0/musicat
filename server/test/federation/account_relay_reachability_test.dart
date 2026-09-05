import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

/// **The payoff of Fase 5 item 3, end to end: two people who become friends
/// purely through the account service can actually use that friendship.**
///
/// ADR 0050 shipped the account-friend sync and named the gap it left:
/// `DeviceLink` recorded no reachability at all, so a synced friend had zero
/// candidates and browsing them failed with `502 Friend unreachable`. Each
/// side could verify the other's signed requests; neither could initiate
/// one. This file is the regression test for that being closed.
///
/// Everything here is real and in one process, composed exactly the way
/// `bin/relay.dart` composes it: one HTTP server hosting the account service
/// at `/accounts/` *and* [RelayHub] at `/`, with the hub handed to
/// [buildAccountRouter] as its `deviceNotifier`. The two nodes are real
/// [startMusicatServer] instances with real Ed25519 identities, real
/// Argon2id logins, real relay tunnels, and real signed federation requests.
///
/// Two properties are load-bearing, and both are asserted rather than
/// assumed:
///
/// 1. **Neither node ever learns an address for the other.** Not through
///    pairing (there is no pairing code anywhere in this file), not through
///    the account service (it records none). The only way the download can
///    possibly work is the relay.
/// 2. **`accountPollInterval` is 12 hours**, so nothing here can be
///    explained by a background poll happening to fire. Every convergence
///    below is caused by either the relay push or the forced refresh a route
///    performs before answering.
void main() {
  late Directory relayDataDir;
  late Directory aliceDir;
  late Directory bobDir;
  late RelayHub hub;
  late AccountStore accountStore;
  late FriendRequestStore friendRequestStore;
  late HttpServer relayServer;
  late String relayWsUrl;
  late String accountServiceUrl;
  late MusicatServerHandle alice;
  late MusicatServerHandle bob;
  late File musicFile;

  String aliceUrl(String path) => 'http://localhost:${alice.port}$path';
  String bobUrl(String path) => 'http://localhost:${bob.port}$path';

  setUp(() async {
    relayDataDir = Directory.systemTemp.createTempSync('musicat_arr_relay_');
    aliceDir = Directory.systemTemp.createTempSync('musicat_arr_alice_');
    bobDir = Directory.systemTemp.createTempSync('musicat_arr_bob_');

    // `bin/relay.dart`, in-process: the account service mounted *before* the
    // hub's catch-all forwarding route, and the hub itself passed in as the
    // account service's DeviceNotifier.
    hub = RelayHub(dataDir: relayDataDir);
    accountStore = AccountStore(relayDataDir);
    friendRequestStore = FriendRequestStore(relayDataDir);
    final router = Router()
      ..mount(
        '/accounts/',
        buildAccountRouter(
          accountStore,
          friendRequestStore,
          deviceNotifier: hub,
        ).call,
      )
      ..mount('/', hub.buildRouter().call);
    relayServer = await shelf_io.serve(router.call, 'localhost', 0);
    relayWsUrl = 'ws://localhost:${relayServer.port}/connect';
    accountServiceUrl = 'http://localhost:${relayServer.port}/accounts';

    musicFile = File('${bobDir.path}/track.flac')
      ..writeAsBytesSync(List<int>.generate(4096, (i) => i % 256));

    Future<MusicatServerHandle> startNode(Directory dir) => startMusicatServer(
      dataDir: dir,
      port: 0,
      relayUrl: relayWsUrl,
      accountServiceUrl: accountServiceUrl,
      // Long enough that neither background job can fire during this test:
      // every convergence below has to be caused by a push or by a route's
      // own forced refresh, never by a poll that happened to land.
      friendDeviceRefreshInterval: const Duration(hours: 12),
      accountPollInterval: const Duration(hours: 12),
    );

    alice = await startNode(aliceDir);
    bob = await startNode(bobDir);
    expect(alice.relayUrl, relayWsUrl, reason: 'Alice must have a relay');
    expect(bob.relayUrl, relayWsUrl, reason: 'Bob must have a relay');
  });

  tearDown(() async {
    await alice.close();
    await bob.close();
    await relayServer.close(force: true);
    relayDataDir.deleteSync(recursive: true);
    aliceDir.deleteSync(recursive: true);
    bobDir.deleteSync(recursive: true);
  });

  Future<String> logIn(MusicatServerHandle node, String username) async {
    final response = await http.post(
      Uri.parse('http://localhost:${node.port}/api/v1/account/login'),
      body: jsonEncode({'username': username, 'password': 'hunter2-correct'}),
    );
    expect(response.statusCode, 200, reason: response.body);
    return (jsonDecode(response.body) as Map<String, dynamic>)['accountId']
        as String;
  }

  Future<void> waitUntil(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 15),
    String? reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(reason ?? 'Condition not met within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('two accounts befriended entirely through the account service list '
      'and download from each other over the relay, with no address known '
      'anywhere', () async {
    final aliceAccountId = await logIn(alice, 'alice');
    final bobAccountId = await logIn(bob, 'bob');

    // --- Alice asks Bob to be friends. By username: she has never seen his
    // nodeId, his address, or a pairing code.
    final sent = await http.post(
      Uri.parse(aliceUrl('/api/v1/account/friend-requests')),
      body: jsonEncode({'toUsername': 'bob'}),
    );
    expect(sent.statusCode, 201, reason: sent.body);
    final requestId =
        (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;

    // --- Bob sees it and accepts. His accept forces a refresh before
    // answering, so Alice is already a real local friend by the time it
    // returns.
    final incoming = await http.get(
      Uri.parse(bobUrl('/api/v1/account/friend-requests')),
    );
    expect(
      ((jsonDecode(incoming.body) as Map<String, dynamic>)['requests']
              as List<dynamic>)
          .single['fromUsername'],
      'alice',
    );
    final accepted = await http.post(
      Uri.parse(bobUrl('/api/v1/account/friend-requests/$requestId/accept')),
    );
    expect(accepted.statusCode, 200, reason: accepted.body);

    // --- Alice finds out *without asking*: the account service pushed a
    // contentless nudge down her relay tunnel, and her node re-fetched. With
    // the poll interval at 12 hours, nothing else could have done this.
    await waitUntil(
      () async =>
          (await FriendStore(aliceDir).findByAccountId(bobAccountId)) != null,
      reason:
          "Alice's node never learned about the accepted friendship. The "
          'relay push (or the re-fetch it triggers) is broken -- the poll '
          'interval is 12h, so nothing else could have converged this.',
    );

    // --- The property that makes this test mean anything: neither side has
    // an address for the other, only a relay.
    for (final (dir, friendId, label) in [
      (aliceDir, bobAccountId, 'Bob'),
      (bobDir, aliceAccountId, 'Alice'),
    ]) {
      final friend = await FriendStore(dir).findByAccountId(friendId);
      expect(friend, isNotNull, reason: '$label should be a friend');
      final device = friend!.devices.single;
      expect(
        device.address,
        isNull,
        reason:
            'No pairing happened, so $label must have no address at all -- '
            'if this ever becomes non-null the download below stops proving '
            'anything about the relay.',
      );
      expect(device.udpCandidate, isNull);
      expect(
        device.relayUrl,
        relayWsUrl,
        reason: 'The relay endpoint is the only reachability that exists.',
      );
    }

    // --- Bob shares a track with Alice's *account*.
    final shared = await http.post(
      Uri.parse(bobUrl('/api/v1/library/shared-tracks')),
      body: jsonEncode({
        'filePath': musicFile.path,
        'title': 'Digital Love',
        'artist': 'Daft Punk',
        'visibility': {'type': 'friend', 'nodeId': aliceAccountId},
      }),
    );
    expect(shared.statusCode, 201, reason: shared.body);
    final trackId =
        (jsonDecode(shared.body) as Map<String, dynamic>)['id'] as String;

    // --- Alice lists it. This can only travel one way: her node has no
    // address for Bob, so `reachFriend` produces exactly one candidate,
    // `<relay http origin>/<bob nodeId>/<path>`.
    final listed = await http
        .get(
          Uri.parse(
            aliceUrl('/api/v1/library/friends/$bobAccountId/shared-tracks'),
          ),
        )
        .timeout(const Duration(seconds: 30));
    expect(listed.statusCode, 200, reason: listed.body);
    final tracks = jsonDecode(listed.body) as List<dynamic>;
    expect(tracks, hasLength(1));
    expect((tracks.single as Map<String, dynamic>)['title'], 'Digital Love');

    // --- ...and downloads the real bytes, through the same tunnel.
    final download = await http
        .get(
          Uri.parse(
            aliceUrl(
              '/api/v1/library/friends/$bobAccountId'
              '/shared-tracks/$trackId/file',
            ),
          ),
        )
        .timeout(const Duration(seconds: 30));
    expect(download.statusCode, 200, reason: download.body);
    expect(download.bodyBytes, musicFile.readAsBytesSync());
  });

  test('a node with no relay configured publishes none, and stays reachable '
      'only by whatever address a friend already has', () async {
    // Carol runs without a relay at all -- the entirely normal case for
    // someone who has never set one up.
    final carolDir = Directory.systemTemp.createTempSync('musicat_arr_carol_');
    addTearDown(() => carolDir.deleteSync(recursive: true));
    final carol = await startMusicatServer(
      dataDir: carolDir,
      port: 0,
      accountServiceUrl: accountServiceUrl,
      friendDeviceRefreshInterval: const Duration(hours: 12),
      accountPollInterval: const Duration(hours: 12),
    );
    addTearDown(carol.close);
    expect(carol.relayUrl, isNull);

    final carolAccountId = await logIn(carol, 'carol');

    // Nothing was published on her behalf: the account service records no
    // reachability it wasn't given.
    final stored = await accountStore.findById(carolAccountId);
    expect(stored!.devices.single.relayUrl, isNull);

    // And a friend who syncs her gets a friend they cannot initiate to --
    // still a real, if narrow, limitation, and one worth failing fast on
    // rather than hanging.
    await logIn(alice, 'alice');
    final sent = await http.post(
      Uri.parse(aliceUrl('/api/v1/account/friend-requests')),
      body: jsonEncode({'toUsername': 'carol'}),
    );
    final requestId =
        (jsonDecode(sent.body) as Map<String, dynamic>)['id'] as String;
    final accepted = await http.post(
      Uri.parse(
        'http://localhost:${carol.port}'
        '/api/v1/account/friend-requests/$requestId/accept',
      ),
    );
    expect(accepted.statusCode, 200);

    final carolAsAliceSeesHer = await waitForFriend(aliceDir, carolAccountId);
    expect(carolAsAliceSeesHer.devices.single.address, isNull);
    expect(carolAsAliceSeesHer.devices.single.relayUrl, isNull);

    final stopwatch = Stopwatch()..start();
    final browse = await http
        .get(
          Uri.parse(
            aliceUrl('/api/v1/library/friends/$carolAccountId/shared-tracks'),
          ),
        )
        .timeout(const Duration(seconds: 20));
    stopwatch.stop();

    expect(browse.statusCode, 502);
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'No candidates means no attempt to time out.',
    );
  });
}

/// Polls [dir]'s [FriendStore] until [accountId] shows up, which is how long
/// a relay push plus a re-fetch takes -- never a fixed sleep.
Future<Friend> waitForFriend(Directory dir, String accountId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final friend = await FriendStore(dir).findByAccountId(accountId);
    if (friend != null) return friend;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('$accountId never became a friend of $dir');
}
