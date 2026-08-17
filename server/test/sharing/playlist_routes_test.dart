import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musicat_server/src/federation/friend.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/sharing/joint_playlist.dart';
import 'package:musicat_server/src/sharing/joint_playlist_store.dart';
import 'package:musicat_server/src/sharing/playlist_item.dart';
import 'package:musicat_server/src/sharing/playlist_routes.dart';
import 'package:musicat_server/src/sharing/shared_track_store.dart';
import 'package:musicat_server/src/sharing/sharing_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory serverDir;
  late Directory friendDir;
  late Directory friend2Dir;
  late Directory outsiderDir;
  late File musicFile;
  late JointPlaylistStore playlistStore;
  late SharedTrackStore sharedTrackStore;
  late FriendStore friendStore;
  late NodeIdentity identity;
  late NodeIdentity friend;
  late NodeIdentity friend2;
  late NodeIdentity outsider;

  setUp(() async {
    serverDir = Directory.systemTemp.createTempSync('musicat_playlist_routes_');
    friendDir = Directory.systemTemp.createTempSync('musicat_playlist_friend_');
    friend2Dir = Directory.systemTemp.createTempSync(
      'musicat_playlist_friend2_',
    );
    outsiderDir = Directory.systemTemp.createTempSync(
      'musicat_playlist_outsider_',
    );
    musicFile = File('${serverDir.path}/track.flac')
      ..writeAsBytesSync([1, 2, 3]);

    playlistStore = JointPlaylistStore(serverDir);
    sharedTrackStore = SharedTrackStore(serverDir);
    friendStore = FriendStore(serverDir);
    identity = await NodeIdentityStore(serverDir).loadOrCreate();
    friend = await NodeIdentityStore(friendDir).loadOrCreate();
    friend2 = await NodeIdentityStore(friend2Dir).loadOrCreate();
    // A real, trusted friend of this node's -- just not a member of the
    // playlists these tests create. Used to prove tracks added to an
    // N-participant playlist aren't leaked beyond its actual members.
    outsider = await NodeIdentityStore(outsiderDir).loadOrCreate();

    for (final f in [friend, friend2, outsider]) {
      await friendStore.add(
        Friend(
          nodeId: f.nodeId,
          publicKeyBase64: await f.publicKeyBase64(),
          address: '${f.nodeId}.example:8080',
        ),
      );
    }
  });

  tearDown(() {
    serverDir.deleteSync(recursive: true);
    friendDir.deleteSync(recursive: true);
    friend2Dir.deleteSync(recursive: true);
    outsiderDir.deleteSync(recursive: true);
  });

  group('buildPlaylistRouter', () {
    Handler handlerWith(http.Client httpClient) => buildPlaylistRouter(
      playlistStore,
      sharedTrackStore,
      friendStore,
      identity,
      httpClient: httpClient,
    ).call;

    Future<Response> post(Handler handler, String path, Object body) async =>
        await handler(
          Request(
            'POST',
            Uri.parse('http://localhost$path'),
            body: jsonEncode(body),
          ),
        );
    Future<Response> get(Handler handler, String path) async =>
        await handler(Request('GET', Uri.parse('http://localhost$path')));
    Future<Response> delete(Handler handler, String path) async =>
        await handler(Request('DELETE', Uri.parse('http://localhost$path')));

    test('creates and lists a playlist', () async {
      final handler = handlerWith(
        MockClient((_) async => http.Response('', 500)),
      );

      final createResponse = await post(handler, '/playlists', {
        'name': 'Road trip',
        'participantNodeIds': [friend.nodeId],
      });
      expect(createResponse.statusCode, 201);
      final id =
          jsonDecode(await createResponse.readAsString())['id'] as String;

      final listResponse = await get(handler, '/playlists');
      final list =
          jsonDecode(await listResponse.readAsString()) as List<dynamic>;
      expect(list, hasLength(1));
      expect((list.single as Map)['id'], id);
    });

    test('rejects an empty participant list', () async {
      final handler = handlerWith(
        MockClient((_) async => http.Response('', 500)),
      );
      final response = await post(handler, '/playlists', {
        'name': 'x',
        'participantNodeIds': <String>[],
      });
      expect(response.statusCode, 400);
    });

    test('joins an existing playlist id when one is supplied', () async {
      final handler = handlerWith(
        MockClient((_) async => http.Response('', 500)),
      );
      final response = await post(handler, '/playlists', {
        'id': 'shared-id-from-a-friend',
        'name': 'Road trip',
        'participantNodeIds': [friend.nodeId],
      });

      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      expect(body['id'], 'shared-id-from-a-friend');
    });

    test(
      'adding an item creates a shared track and appends a playlist item',
      () async {
        final handler = handlerWith(
          MockClient((_) async => http.Response('', 500)),
        );
        final createResponse = await post(handler, '/playlists', {
          'name': 'Road trip',
          'participantNodeIds': [friend.nodeId],
        });
        final id =
            jsonDecode(await createResponse.readAsString())['id'] as String;

        final addResponse = await post(handler, '/playlists/$id/items', {
          'filePath': musicFile.path,
          'title': 'One More Time',
          'artist': 'Daft Punk',
        });
        expect(addResponse.statusCode, 201);

        final playlist = await playlistStore.findById(id);
        expect(playlist?.items, hasLength(1));
        final item = playlist!.items.single;
        expect(item.title, 'One More Time');
        expect(item.ownerNodeId, identity.nodeId);

        final sharedTrack = await sharedTrackStore.findById(item.sharedTrackId);
        expect(sharedTrack, isNotNull);
        expect(sharedTrack!.visibility.allows(friend.nodeId), isTrue);
        expect(sharedTrack.visibility.allows('some-other-node'), isFalse);
      },
    );

    test(
      'with more than one other participant, a shared item stays scoped to '
      'exactly those participants -- never widened to every friend',
      () async {
        // Regression test: an earlier version fell back to
        // AllFriendsVisibility whenever a playlist had more than one other
        // participant, which would have leaked the track to `outsider`
        // here even though they're not in this playlist at all.
        final handler = handlerWith(
          MockClient((_) async => http.Response('', 500)),
        );
        final createResponse = await post(handler, '/playlists', {
          'name': 'Group trip',
          'participantNodeIds': [friend.nodeId, friend2.nodeId],
        });
        final id =
            jsonDecode(await createResponse.readAsString())['id'] as String;

        await post(handler, '/playlists/$id/items', {
          'filePath': musicFile.path,
          'title': 'One More Time',
          'artist': 'Daft Punk',
        });

        final playlist = await playlistStore.findById(id);
        final sharedTrack = await sharedTrackStore.findById(
          playlist!.items.single.sharedTrackId,
        );

        expect(sharedTrack!.visibility.allows(friend.nodeId), isTrue);
        expect(sharedTrack.visibility.allows(friend2.nodeId), isTrue);
        expect(sharedTrack.visibility.allows(outsider.nodeId), isFalse);
      },
    );

    test('rejects adding an item whose file does not exist', () async {
      final handler = handlerWith(
        MockClient((_) async => http.Response('', 500)),
      );
      final createResponse = await post(handler, '/playlists', {
        'name': 'x',
        'participantNodeIds': [friend.nodeId],
      });
      final id =
          jsonDecode(await createResponse.readAsString())['id'] as String;

      final response = await post(handler, '/playlists/$id/items', {
        'filePath': '/does/not/exist.flac',
        'title': 'x',
        'artist': 'y',
      });
      expect(response.statusCode, 404);
    });

    test('deletes a playlist', () async {
      final handler = handlerWith(
        MockClient((_) async => http.Response('', 500)),
      );
      final createResponse = await post(handler, '/playlists', {
        'name': 'x',
        'participantNodeIds': [friend.nodeId],
      });
      final id =
          jsonDecode(await createResponse.readAsString())['id'] as String;

      final deleteResponse = await delete(handler, '/playlists/$id');
      expect(deleteResponse.statusCode, 204);
      expect(await playlistStore.findById(id), isNull);
    });

    test('sync pulls the participant\'s view and merges it in', () async {
      final remotePlaylist = JointPlaylist(
        id: 'shared-id',
        name: 'Road trip',
        participantNodeIds: [identity.nodeId],
        items: [
          PlaylistItem(
            id: 'from-friend',
            title: 'Around the World',
            artist: 'Daft Punk',
            ownerNodeId: friend.nodeId,
            sharedTrackId: 'their-shared-id',
            addedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        updatedAt: DateTime.utc(2026, 1, 1),
      );

      await playlistStore.save(
        JointPlaylist(
          id: 'shared-id',
          name: 'Road trip',
          participantNodeIds: [friend.nodeId],
          items: const [],
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
      );

      var requestedPath = '';
      final handler = handlerWith(
        MockClient((request) async {
          requestedPath = request.url.path;
          return http.Response(jsonEncode(remotePlaylist.toJson()), 200);
        }),
      );

      final response = await post(handler, '/playlists/shared-id/sync', {});
      expect(response.statusCode, 200);
      expect(requestedPath, '/api/v1/sharing/playlists/shared-id');

      final merged = await playlistStore.findById('shared-id');
      expect(merged?.items.map((i) => i.id), {'from-friend'});
    });
  });

  group('buildSharingFederationRouter playlists', () {
    Future<Map<String, String>> signHeaders(String path) =>
        RequestSigner(friend).sign(method: 'GET', path: path);

    test('a participant can fetch this node\'s view of the playlist', () async {
      await playlistStore.save(
        JointPlaylist(
          id: 'p1',
          name: 'x',
          participantNodeIds: [friend.nodeId],
          items: const [],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      final handler = buildSharingFederationRouter(
        sharedTrackStore,
        playlistStore,
        RequestVerifier(friendStore),
      ).call;

      final headers = await signHeaders('/playlists/p1');
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/playlists/p1'),
          headers: headers,
        ),
      );

      expect(response.statusCode, 200);
    });

    test('a real friend who is not a participant gets 403', () async {
      await playlistStore.save(
        JointPlaylist(
          id: 'p1',
          name: 'x',
          participantNodeIds: const ['someone-else'],
          items: const [],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      final handler = buildSharingFederationRouter(
        sharedTrackStore,
        playlistStore,
        RequestVerifier(friendStore),
      ).call;

      final headers = await signHeaders('/playlists/p1');
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/playlists/p1'),
          headers: headers,
        ),
      );

      expect(response.statusCode, 403);
    });
  });
}
