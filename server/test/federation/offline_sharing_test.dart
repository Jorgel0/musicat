import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/musicat_server_runtime.dart';
import 'package:musicat_server/src/accounts/account_session_store.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:test/test.dart';

/// The offline rule, tested for real: two already-established friends must
/// be able to complete a full share + download with the account service
/// **completely unreachable**.
///
/// Both nodes are real `startMusicatServer` instances (so this goes through
/// the actually-mounted routes, not a router called directly), talking to
/// each other over real HTTP.
///
/// The account service they point at is a real listening socket that
/// **records every request it receives and then never answers** — a
/// blackhole, not a closed port, and that distinction is the whole point.
/// A closed port refuses in about 14ms, which is indistinguishable from not
/// being called at all: an earlier version of this file used one, and would
/// have stayed green even if the account service were consulted on every
/// single request. A blackhole costs `AccountServiceClient.timeout` (5s)
/// per call, so a call that shouldn't happen becomes unmissable.
///
/// That makes the load-bearing assertion structural rather than a latency
/// heuristic: the established-friend paths assert **zero recorded
/// requests** — the account service wasn't merely too slow to matter, it
/// was never asked. [expectAccountServiceUntouched] is that check, and the
/// stranger test below deliberately asserts the *opposite*, so the recorder
/// is proven to work and the zero-assertions can't be quietly vacuous.
void main() {
  late Directory aliceDir;
  late Directory bobDir;
  late Directory strangerDir;
  late MusicatServerHandle alice;
  late MusicatServerHandle bob;
  late NodeIdentity bobSecondDevice;
  late NodeIdentity stranger;
  late HttpServer accountService;
  late List<String> accountServiceCalls;
  late List<HttpRequest> heldOpen;
  late String accountServiceUrl;
  late int closedDevicePort;
  late File musicFile;

  const aliceAccountId = 'account-alice-0001';
  const bobAccountId = 'account-bob-0002';

  String aliceUrl(String path) => 'http://localhost:${alice.port}$path';
  String bobUrl(String path) => 'http://localhost:${bob.port}$path';

  setUp(() async {
    aliceDir = Directory.systemTemp.createTempSync('musicat_offline_alice_');
    bobDir = Directory.systemTemp.createTempSync('musicat_offline_bob_');
    strangerDir = Directory.systemTemp.createTempSync(
      'musicat_offline_stranger_',
    );

    // The account-service blackhole: accept the connection, write down
    // what was asked, and never reply. Requests are held open (not closed)
    // so a caller genuinely waits out its own timeout, exactly as it would
    // against a box that has stopped answering rather than one refusing.
    accountServiceCalls = [];
    heldOpen = [];
    accountService = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    accountService.listen((request) {
      accountServiceCalls.add('${request.method} ${request.uri.path}');
      heldOpen.add(request);
    });
    accountServiceUrl = 'http://localhost:${accountService.port}/accounts';

    // Separately, a port that is genuinely closed -- used below as a stale
    // *device* address, where refusing fast is the realistic behaviour and
    // is exactly what should happen.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    closedDevicePort = probe.port;
    await probe.close();

    musicFile = File('${aliceDir.path}/track.flac')
      ..writeAsBytesSync(List<int>.generate(2048, (i) => i % 256));

    alice = await startMusicatServer(
      dataDir: aliceDir,
      port: 0,
      accountServiceUrl: accountServiceUrl,
      // Long enough that the scheduled refresh can never fire during a
      // test -- the point here is the *absence* of account-service traffic.
      friendDeviceRefreshInterval: const Duration(hours: 12),
    );
    bob = await startMusicatServer(
      dataDir: bobDir,
      port: 0,
      accountServiceUrl: accountServiceUrl,
      friendDeviceRefreshInterval: const Duration(hours: 12),
    );
    bobSecondDevice = await NodeIdentityStore(
      Directory('${bobDir.path}/second_device')..createSync(),
    ).loadOrCreate();
    stranger = await NodeIdentityStore(strangerDir).loadOrCreate();

    // Both sides already know each other as *account* friends, each with
    // several devices -- i.e. the state a completed friend-request flow
    // leaves behind. Nothing below is allowed to need the account service
    // to make sense of it.
    await FriendStore(aliceDir).add(
      Friend(
        accountId: bobAccountId,
        devices: [
          FriendDevice(
            nodeId: bob.identity.nodeId,
            publicKeyBase64: bob.publicKeyBase64,
            address: 'localhost:${bob.port}',
            linkedAt: DateTime.utc(2026, 1, 1),
          ),
          // Bob's other device: a real key, no address of its own.
          FriendDevice(
            nodeId: bobSecondDevice.nodeId,
            publicKeyBase64: await bobSecondDevice.publicKeyBase64(),
            linkedAt: DateTime.utc(2026, 6, 1),
          ),
        ],
        displayName: 'Bob',
      ),
    );
    await FriendStore(bobDir).add(
      Friend(
        accountId: aliceAccountId,
        devices: [
          // A stale device that answers nowhere, deliberately the most
          // recently linked one so it is tried *first*: reaching Alice has
          // to fall through to her real device without any help from the
          // account service.
          FriendDevice(
            nodeId: 'alice-old-phone',
            publicKeyBase64: bob.publicKeyBase64, // never used to verify
            address: 'localhost:$closedDevicePort',
            linkedAt: DateTime.utc(2026, 6, 1),
          ),
          FriendDevice(
            nodeId: alice.identity.nodeId,
            publicKeyBase64: alice.publicKeyBase64,
            address: 'localhost:${alice.port}',
            linkedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        displayName: 'Alice',
      ),
    );
  });

  tearDown(() async {
    await alice.close();
    await bob.close();
    // Held-open requests are abandoned rather than answered; `force: true`
    // is what actually releases their sockets.
    for (final request in heldOpen) {
      await request.response.close().catchError((_) {});
    }
    await accountService.close(force: true);
    aliceDir.deleteSync(recursive: true);
    bobDir.deleteSync(recursive: true);
    strangerDir.deleteSync(recursive: true);
  });

  /// The structural half of the offline rule: not "the account service was
  /// too slow to have mattered", but "the account service was never asked".
  /// See this file's own doc comment for why a latency assertion isn't
  /// enough to prove this.
  void expectAccountServiceUntouched() => expect(
    accountServiceCalls,
    isEmpty,
    reason:
        'The offline rule is that an established friend is served entirely '
        'from local disk. Something on that path called the account '
        'service.',
  );

  /// Shares [musicFile] from Alice with whatever [visibilityId] names, via
  /// her own app-facing API, and returns the new track's id.
  Future<String> shareWithAlicesApi(String visibilityId) async {
    final response = await http.post(
      Uri.parse(aliceUrl('/api/v1/library/shared-tracks')),
      body: jsonEncode({
        'filePath': musicFile.path,
        'title': 'Around the World',
        'artist': 'Daft Punk',
        'visibility': {'type': 'friend', 'nodeId': visibilityId},
      }),
    );
    expect(response.statusCode, 201);
    return (jsonDecode(response.body) as Map<String, dynamic>)['id'] as String;
  }

  test('a full share + download between two established friends works with '
      'the account service completely unreachable', () async {
    // The app hands over whichever id it has for the friend -- here Bob's
    // *device* nodeId, which is what every id stored before Fase 5 is.
    final trackId = await shareWithAlicesApi(bob.identity.nodeId);

    // It was stored against Bob's *account*, not that one device.
    final ownShares =
        jsonDecode(
              (await http.get(
                Uri.parse(aliceUrl('/api/v1/library/shared-tracks')),
              )).body,
            )
            as List<dynamic>;
    expect((ownShares.single as Map<String, dynamic>)['visibility'], {
      'type': 'friends',
      'nodeIds': [bobAccountId],
    });

    // Bob browses what Alice shared with him, through his own server
    // (which signs the federation call for him), addressing her by her
    // accountId.
    final listed = await http
        .get(
          Uri.parse(
            bobUrl('/api/v1/library/friends/$aliceAccountId/shared-tracks'),
          ),
        )
        .timeout(const Duration(seconds: 20));
    expect(listed.statusCode, 200);
    final tracks = jsonDecode(listed.body) as List<dynamic>;
    expect(tracks, hasLength(1));
    expect((tracks.single as Map<String, dynamic>)['id'], trackId);
    expect(
      (tracks.single as Map<String, dynamic>)['title'],
      'Around the World',
    );

    // ...and downloads the real bytes.
    final download = await http
        .get(
          Uri.parse(
            bobUrl(
              '/api/v1/library/friends/$aliceAccountId/shared-tracks/$trackId/file',
            ),
          ),
        )
        .timeout(const Duration(seconds: 20));
    expect(download.statusCode, 200);
    expect(download.bodyBytes, musicFile.readAsBytesSync());
    expectAccountServiceUntouched();
  });

  test('the same works when the app addresses the friend by a device nodeId '
      'instead of their accountId', () async {
    final trackId = await shareWithAlicesApi(bobAccountId);

    final download = await http
        .get(
          Uri.parse(
            bobUrl(
              '/api/v1/library/friends/${alice.identity.nodeId}'
              '/shared-tracks/$trackId/file',
            ),
          ),
        )
        .timeout(const Duration(seconds: 20));

    expect(download.statusCode, 200);
    expect(download.bodyBytes, musicFile.readAsBytesSync());
    expectAccountServiceUntouched();
  });

  test("any of the friend account's devices may download, offline", () async {
    final trackId = await shareWithAlicesApi(bobAccountId);
    final path = '/api/v1/sharing/shared-tracks/$trackId/file';

    // Bob's second device signs Alice's federation endpoint directly: same
    // account, a different key, no account service involved.
    final headers = await RequestSigner(
      bobSecondDevice,
    ).sign(method: 'GET', path: path);
    final response = await http
        .get(Uri.parse(aliceUrl(path)), headers: headers)
        .timeout(const Duration(seconds: 20));

    expect(response.statusCode, 200);
    expect(response.bodyBytes, musicFile.readAsBytesSync());
  });

  test('a stranger is still rejected, promptly, rather than hanging on an '
      'unreachable account service', () async {
    final trackId = await shareWithAlicesApi(bobAccountId);
    final path = '/api/v1/sharing/shared-tracks/$trackId/file';
    final headers = await RequestSigner(
      stranger,
    ).sign(method: 'GET', path: path);

    final response = await http
        .get(Uri.parse(aliceUrl(path)), headers: headers)
        .timeout(const Duration(seconds: 20));

    expect(response.statusCode, 401);
    // The inverse of every other assertion in this file, and the reason
    // they mean anything: an *unknown* nodeId is the one case that is
    // supposed to reach the account service (it may be a friend's newly
    // linked device), so seeing a recorded call here proves the recorder
    // is wired up and `expectAccountServiceUntouched` isn't vacuous.
    expect(
      accountServiceCalls,
      isNotEmpty,
      reason:
          'An unknown nodeId should consult the account service once; if '
          'it no longer does, every zero-call assertion here is vacuous.',
    );
  });

  test('a logged-in node still serves an established friend without ever '
      'touching the account service', () async {
    // Rule 1 with a *session* on disk, which is the state everything added
    // for the account-friend sync runs in. Being logged in must not put the
    // account service anywhere near the path of serving a friend, and
    // nothing at startup may kick off a sync on its own.
    await AccountSessionStore(
      aliceDir,
    ).save(accountId: aliceAccountId, username: 'alice');
    final relogged = await startMusicatServer(
      dataDir: aliceDir,
      port: 0,
      accountServiceUrl: accountServiceUrl,
      friendDeviceRefreshInterval: const Duration(hours: 12),
    );
    addTearDown(relogged.close);
    accountServiceCalls.clear();

    // Reading who this node is: local disk, no call.
    final session = await http
        .get(Uri.parse('http://localhost:${relogged.port}/api/v1/account'))
        .timeout(const Duration(seconds: 5));
    expect(session.statusCode, 200);
    expect(
      ((jsonDecode(session.body) as Map<String, dynamic>)['account']
          as Map<String, dynamic>)['accountId'],
      aliceAccountId,
    );

    // ...and Bob, an established friend, still downloads from her.
    final trackId = await shareWithAlicesApi(bobAccountId);
    final path = '/api/v1/sharing/shared-tracks/$trackId/file';
    final headers = await RequestSigner(
      bobSecondDevice,
    ).sign(method: 'GET', path: path);
    final download = await http
        .get(
          Uri.parse('http://localhost:${relogged.port}$path'),
          headers: headers,
        )
        .timeout(const Duration(seconds: 20));
    expect(download.statusCode, 200);
    expect(download.bodyBytes, musicFile.readAsBytesSync());

    expectAccountServiceUntouched();
  });

  test('logging out never touches the friend list, and needs no account '
      'service either', () async {
    await AccountSessionStore(
      aliceDir,
    ).save(accountId: aliceAccountId, username: 'alice');
    final trackId = await shareWithAlicesApi(bobAccountId);
    accountServiceCalls.clear();

    final loggedOut = await http
        .delete(Uri.parse(aliceUrl('/api/v1/account')))
        .timeout(const Duration(seconds: 5));
    expect(loggedOut.statusCode, 204);

    // Bob is still a friend, and can still download.
    expect(
      await FriendStore(aliceDir).findByAccountId(bobAccountId),
      isNotNull,
    );
    final path = '/api/v1/sharing/shared-tracks/$trackId/file';
    final headers = await RequestSigner(
      bobSecondDevice,
    ).sign(method: 'GET', path: path);
    final download = await http
        .get(Uri.parse(aliceUrl(path)), headers: headers)
        .timeout(const Duration(seconds: 20));
    expect(download.statusCode, 200);
    expectAccountServiceUntouched();
  });

  test('unfriending still takes effect instantly with the account service '
      'unreachable', () async {
    final trackId = await shareWithAlicesApi(bobAccountId);

    final revoked = await http
        .delete(Uri.parse(aliceUrl('/api/v1/federation/friends/$bobAccountId')))
        .timeout(const Duration(seconds: 20));
    expect(revoked.statusCode, 204);

    final path = '/api/v1/sharing/shared-tracks/$trackId/file';
    final headers = await RequestSigner(
      bobSecondDevice,
    ).sign(method: 'GET', path: path);
    final response = await http
        .get(Uri.parse(aliceUrl(path)), headers: headers)
        .timeout(const Duration(seconds: 20));

    expect(response.statusCode, 401);
    expect(await FriendStore(aliceDir).isRemoved(bobAccountId), isTrue);
    // Removal is local disk and nothing else -- a tombstoned account is
    // refused before any lookup, so not even the rejection costs a call.
    expectAccountServiceUntouched();
  });
}
