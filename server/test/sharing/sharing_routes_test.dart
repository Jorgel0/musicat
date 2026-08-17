import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/sharing/joint_playlist_store.dart';
import 'package:musicat_server/src/sharing/shared_track.dart';
import 'package:musicat_server/src/sharing/shared_track_store.dart';
import 'package:musicat_server/src/sharing/sharing_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory serverDir;
  late Directory friend1Dir;
  late Directory friend2Dir;
  late File musicFile;
  late File coverFile;
  late SharedTrackStore store;
  late FriendStore friendStore;
  late NodeIdentity serverIdentity;
  late NodeIdentity friend1;
  late NodeIdentity friend2;
  late Handler libraryHandler;
  late Handler sharingHandler;

  setUp(() async {
    serverDir = Directory.systemTemp.createTempSync('musicat_sharing_server_');
    friend1Dir = Directory.systemTemp.createTempSync('musicat_sharing_f1_');
    friend2Dir = Directory.systemTemp.createTempSync('musicat_sharing_f2_');

    musicFile = File('${serverDir.path}/track.flac')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    coverFile = File('${serverDir.path}/cover.jpg')
      ..writeAsBytesSync([9, 8, 7]);

    store = SharedTrackStore(serverDir);
    friendStore = FriendStore(serverDir);
    serverIdentity = await NodeIdentityStore(serverDir).loadOrCreate();
    friend1 = await NodeIdentityStore(friend1Dir).loadOrCreate();
    friend2 = await NodeIdentityStore(friend2Dir).loadOrCreate();

    await friendStore.add(
      Friend(
        nodeId: friend1.nodeId,
        publicKeyBase64: await friend1.publicKeyBase64(),
        address: 'friend1.example:8080',
      ),
    );
    await friendStore.add(
      Friend(
        nodeId: friend2.nodeId,
        publicKeyBase64: await friend2.publicKeyBase64(),
        address: 'friend2.example:8080',
      ),
    );

    libraryHandler = buildLibraryRouter(
      store,
      friendStore,
      serverIdentity,
    ).call;
    sharingHandler = buildSharingFederationRouter(
      store,
      JointPlaylistStore(serverDir),
      RequestVerifier(friendStore),
    ).call;
  });

  tearDown(() {
    serverDir.deleteSync(recursive: true);
    friend1Dir.deleteSync(recursive: true);
    friend2Dir.deleteSync(recursive: true);
  });

  group('buildLibraryRouter', () {
    Future<Response> post(String path, Object body) async =>
        await libraryHandler(
          Request(
            'POST',
            Uri.parse('http://localhost$path'),
            body: jsonEncode(body),
          ),
        );
    Future<Response> get(String path) async => await libraryHandler(
      Request('GET', Uri.parse('http://localhost$path')),
    );
    Future<Response> delete(String path) async => await libraryHandler(
      Request('DELETE', Uri.parse('http://localhost$path')),
    );

    test('shares a track with a specific friend', () async {
      final response = await post('/shared-tracks', {
        'filePath': musicFile.path,
        'title': 'One More Time',
        'artist': 'Daft Punk',
        'visibility': {'type': 'friend', 'nodeId': friend1.nodeId},
      });

      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      final track = await store.findById(body['id'] as String);
      expect(track?.title, 'One More Time');
      expect(track?.visibility, isA<FriendsVisibility>());
    });

    test('shares a track with all friends', () async {
      final response = await post('/shared-tracks', {
        'filePath': musicFile.path,
        'title': 'Around the World',
        'artist': 'Daft Punk',
        'visibility': {'type': 'allFriends'},
      });

      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      final track = await store.findById(body['id'] as String);
      expect(track?.visibility, isA<AllFriendsVisibility>());
    });

    test('rejects a file that does not exist', () async {
      final response = await post('/shared-tracks', {
        'filePath': '/does/not/exist.flac',
        'title': 'x',
        'artist': 'y',
        'visibility': {'type': 'allFriends'},
      });
      expect(response.statusCode, 404);
    });

    test('rejects an unknown visibility type', () async {
      final response = await post('/shared-tracks', {
        'filePath': musicFile.path,
        'title': 'x',
        'artist': 'y',
        'visibility': {'type': 'everyone-on-earth'},
      });
      expect(response.statusCode, 400);
    });

    test('lists and then deletes a shared track', () async {
      final createResponse = await post('/shared-tracks', {
        'filePath': musicFile.path,
        'title': 'x',
        'artist': 'y',
        'visibility': {'type': 'allFriends'},
      });
      final id =
          jsonDecode(await createResponse.readAsString())['id'] as String;

      final listResponse = await get('/shared-tracks');
      expect(
        jsonDecode(await listResponse.readAsString()) as List<dynamic>,
        hasLength(1),
      );

      final deleteResponse = await delete('/shared-tracks/$id');
      expect(deleteResponse.statusCode, 204);
      expect(await store.findById(id), isNull);
    });
  });

  group('buildLibraryRouter friend proxy', () {
    Future<Response> getViaHandler(Handler handler, String path) async =>
        handler(Request('GET', Uri.parse('http://localhost$path')));

    test('404s for an unknown friend nodeId', () async {
      final handler = buildLibraryRouter(
        store,
        friendStore,
        serverIdentity,
      ).call;
      final response = await getViaHandler(
        handler,
        '/friends/not-a-real-node/shared-tracks',
      );
      expect(response.statusCode, 404);
    });

    test(
      'signs a GET to the friend and returns their shared-tracks list',
      () async {
        http.BaseRequest? captured;
        final handler = buildLibraryRouter(
          store,
          friendStore,
          serverIdentity,
          httpClient: MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode([
                {'id': 't1', 'title': 'Around the World'},
              ]),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ).call;

        final response = await getViaHandler(
          handler,
          '/friends/${friend1.nodeId}/shared-tracks',
        );

        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString()) as List<dynamic>;
        expect((body.single as Map)['title'], 'Around the World');

        expect(captured, isNotNull);
        expect(
          captured!.url,
          Uri.parse('http://friend1.example:8080/api/v1/sharing/shared-tracks'),
        );
        expect(captured!.headers['x-node-id'], serverIdentity.nodeId);
        expect(captured!.headers.containsKey('x-signature'), isTrue);
      },
    );

    test("forwards the friend's error status instead of masking it", () async {
      final handler = buildLibraryRouter(
        store,
        friendStore,
        serverIdentity,
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode({'error': 'nope'}), 403),
        ),
      ).call;

      final response = await getViaHandler(
        handler,
        '/friends/${friend1.nodeId}/shared-tracks',
      );
      expect(response.statusCode, 403);
    });

    test('returns 502 when the friend is unreachable', () async {
      final handler = buildLibraryRouter(
        store,
        friendStore,
        serverIdentity,
        httpClient: MockClient((_) async => throw const SocketException('x')),
      ).call;

      final response = await getViaHandler(
        handler,
        '/friends/${friend1.nodeId}/shared-tracks',
      );
      expect(response.statusCode, 502);
    });

    test('streams a shared track file through from the friend', () async {
      final handler = buildLibraryRouter(
        store,
        friendStore,
        serverIdentity,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/sharing/shared-tracks/t1/file');
          return http.Response.bytes([10, 20, 30], 200);
        }),
      ).call;

      final response = await getViaHandler(
        handler,
        '/friends/${friend1.nodeId}/shared-tracks/t1/file',
      );

      expect(response.statusCode, 200);
      final bytes = await response.read().expand((chunk) => chunk).toList();
      expect(bytes, [10, 20, 30]);
    });

    test('forwards a 403 from the friend on the file proxy too', () async {
      final handler = buildLibraryRouter(
        store,
        friendStore,
        serverIdentity,
        httpClient: MockClient(
          (_) async =>
              http.Response(jsonEncode({'error': 'Not shared with you'}), 403),
        ),
      ).call;

      final response = await getViaHandler(
        handler,
        '/friends/${friend1.nodeId}/shared-tracks/t1/file',
      );
      expect(response.statusCode, 403);
    });

    test('streams cover art through from the friend', () async {
      final handler = buildLibraryRouter(
        store,
        friendStore,
        serverIdentity,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/sharing/shared-tracks/t1/cover');
          return http.Response.bytes([9, 9, 9], 200);
        }),
      ).call;

      final response = await getViaHandler(
        handler,
        '/friends/${friend1.nodeId}/shared-tracks/t1/cover',
      );

      expect(response.statusCode, 200);
      final bytes = await response.read().expand((chunk) => chunk).toList();
      expect(bytes, [9, 9, 9]);
    });
  });

  group('buildSharingFederationRouter', () {
    Future<Map<String, String>> signHeaders(
      NodeIdentity identity,
      String path,
    ) => RequestSigner(identity).sign(method: 'GET', path: path);

    Future<Response> get(String path, Map<String, String> headers) async =>
        await sharingHandler(
          Request('GET', Uri.parse('http://localhost$path'), headers: headers),
        );

    test('GET /shared-tracks rejects an unsigned request', () async {
      final response = await get('/shared-tracks', {});
      expect(response.statusCode, 401);
    });

    test(
      'GET /shared-tracks returns only what is visible to the caller',
      () async {
        await store.add(
          SharedTrack(
            id: 'only-friend1',
            filePath: musicFile.path,
            title: 'Just for friend 1',
            artist: 'Daft Punk',
            visibility: FriendsVisibility({friend1.nodeId}),
          ),
        );
        await store.add(
          const SharedTrack(
            id: 'everyone',
            filePath: '/irrelevant.flac',
            title: 'For everyone',
            artist: 'Daft Punk',
            visibility: AllFriendsVisibility(),
          ),
        );

        final headers = await signHeaders(friend1, '/shared-tracks');
        final response = await get('/shared-tracks', headers);
        final body = jsonDecode(await response.readAsString()) as List<dynamic>;

        expect(response.statusCode, 200);
        expect(body, hasLength(2));
        // Only public fields -- never the local filePath.
        expect(body.every((t) => !(t as Map).containsKey('filePath')), isTrue);
        // The extension is still exposed -- the friend needs it to name/
        // import whatever it downloads, and it reveals nothing about the
        // sharer's actual directory layout.
        expect(body.every((t) => (t as Map)['extension'] == '.flac'), isTrue);

        final headers2 = await signHeaders(friend2, '/shared-tracks');
        final response2 = await get('/shared-tracks', headers2);
        final body2 =
            jsonDecode(await response2.readAsString()) as List<dynamic>;
        expect(body2, hasLength(1));
        expect((body2.single as Map)['id'], 'everyone');
      },
    );

    test(
      'GET /shared-tracks/<id>/file serves the real bytes to the intended friend',
      () async {
        await store.add(
          SharedTrack(
            id: 't1',
            filePath: musicFile.path,
            title: 'x',
            artist: 'y',
            visibility: FriendsVisibility({friend1.nodeId}),
          ),
        );

        final headers = await signHeaders(friend1, '/shared-tracks/t1/file');
        final response = await get('/shared-tracks/t1/file', headers);

        expect(response.statusCode, 200);
        final bytes = await response.read().expand((chunk) => chunk).toList();
        expect(bytes, musicFile.readAsBytesSync());
      },
    );

    test(
      'GET /shared-tracks/<id>/file rejects a known friend it was not shared with',
      () async {
        await store.add(
          SharedTrack(
            id: 't1',
            filePath: musicFile.path,
            title: 'x',
            artist: 'y',
            visibility: FriendsVisibility({friend1.nodeId}),
          ),
        );

        // friend2 is a real, trusted friend -- just not who this track was
        // shared with. This is the object-level authz check.
        final headers = await signHeaders(friend2, '/shared-tracks/t1/file');
        final response = await get('/shared-tracks/t1/file', headers);

        expect(response.statusCode, 403);
      },
    );

    test('GET /shared-tracks/<id>/file 404s for an unknown id', () async {
      final headers = await signHeaders(friend1, '/shared-tracks/nope/file');
      final response = await get('/shared-tracks/nope/file', headers);
      expect(response.statusCode, 404);
    });

    test('GET /shared-tracks/<id>/cover serves cover art bytes', () async {
      await store.add(
        SharedTrack(
          id: 't1',
          filePath: musicFile.path,
          title: 'x',
          artist: 'y',
          coverArtPath: coverFile.path,
          visibility: const AllFriendsVisibility(),
        ),
      );

      final headers = await signHeaders(friend1, '/shared-tracks/t1/cover');
      final response = await get('/shared-tracks/t1/cover', headers);

      expect(response.statusCode, 200);
      final bytes = await response.read().expand((chunk) => chunk).toList();
      expect(bytes, coverFile.readAsBytesSync());
    });

    test('GET /shared-tracks/<id>/cover 404s when there is no cover', () async {
      await store.add(
        SharedTrack(
          id: 't1',
          filePath: musicFile.path,
          title: 'x',
          artist: 'y',
          visibility: const AllFriendsVisibility(),
        ),
      );

      final headers = await signHeaders(friend1, '/shared-tracks/t1/cover');
      final response = await get('/shared-tracks/t1/cover', headers);
      expect(response.statusCode, 404);
    });
  });
}
