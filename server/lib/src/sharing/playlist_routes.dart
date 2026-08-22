import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../federation/friend_reachability.dart';
import '../federation/friend_store.dart';
import '../federation/request_signing.dart';
import '../identity/node_identity.dart';
import 'joint_playlist.dart';
import 'joint_playlist_store.dart';
import 'playlist_item.dart';
import 'shared_track.dart';
import 'shared_track_store.dart';

Response _json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Response _error(String message, {int status = 400}) =>
    _json({'error': message}, status: status);

String _generateId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// App-facing routes for this node's own joint playlists. Same known,
/// deliberate reachability gap as the rest of `/api/v1/library/*` (ADR
/// 0025) — not protected beyond "whoever can reach this server can call it".
Router buildPlaylistRouter(
  JointPlaylistStore playlistStore,
  SharedTrackStore sharedTrackStore,
  FriendStore friendStore,
  NodeIdentity identity, {
  http.Client? httpClient,
}) {
  final client = httpClient ?? http.Client();
  final router = Router();

  router.post('/', (Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final name = body['name'];
    final participants = body['participantNodeIds'];
    final requestedId = body['id'];
    if (name is! String || name.isEmpty) {
      return _error('"name" is required');
    }
    if (participants is! List || participants.isEmpty) {
      return _error('"participantNodeIds" must be a non-empty list');
    }
    if (requestedId != null && requestedId is! String) {
      return _error('"id" must be a string if present');
    }

    // Accepts a caller-supplied id so a friend can *join* a playlist
    // someone else already created (using the id they were given
    // out-of-band) rather than always minting a new, disconnected one —
    // otherwise there'd be no way for two nodes to ever agree on which
    // playlist they're both talking about. How that id actually gets
    // communicated between two people (an invite link, a code, ...) isn't
    // designed yet; this only makes the id itself reusable.
    final playlist = JointPlaylist(
      id: (requestedId as String?) ?? _generateId(),
      name: name,
      participantNodeIds: [for (final id in participants) id as String],
      items: const [],
      updatedAt: DateTime.now().toUtc(),
    );
    await playlistStore.save(playlist);
    return _json({'id': playlist.id}, status: 201);
  });

  router.get('/', (Request request) async {
    final playlists = await playlistStore.loadAll();
    return _json([for (final playlist in playlists) playlist.toJson()]);
  });

  router.get('/<id>', (Request request, String id) async {
    final playlist = await playlistStore.findById(id);
    if (playlist == null) return _error('Not found', status: 404);
    return _json(playlist.toJson());
  });

  router.delete('/<id>', (Request request, String id) async {
    await playlistStore.remove(id);
    return Response(204);
  });

  router.post('/<id>/items', (Request request, String id) async {
    final playlist = await playlistStore.findById(id);
    if (playlist == null) return _error('Not found', status: 404);

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final filePath = body['filePath'];
    final title = body['title'];
    final artist = body['artist'];
    if (filePath is! String || filePath.isEmpty) {
      return _error('"filePath" is required');
    }
    if (title is! String || title.isEmpty) {
      return _error('"title" is required');
    }
    if (artist is! String || artist.isEmpty) {
      return _error('"artist" is required');
    }
    if (!File(filePath).existsSync()) {
      return _error('File not found: $filePath', status: 404);
    }

    // The track is offered to *exactly* this playlist's other
    // participants, whether there's one or several -- never widened to
    // "all friends", which would leak it to friends outside this
    // playlist entirely (see ADR 0027).
    final sharedTrack = SharedTrack(
      id: _generateId(),
      filePath: filePath,
      title: title,
      artist: artist,
      album: body['album'] as String?,
      coverArtPath: body['coverArtPath'] as String?,
      visibility: FriendsVisibility(playlist.participantNodeIds.toSet()),
    );
    await sharedTrackStore.add(sharedTrack);

    final item = PlaylistItem(
      id: _generateId(),
      title: title,
      artist: artist,
      album: body['album'] as String?,
      ownerNodeId: identity.nodeId,
      sharedTrackId: sharedTrack.id,
      extension: extensionOf(filePath),
      addedAt: DateTime.now().toUtc(),
    );
    final updated = playlist.copyWith(
      items: [...playlist.items, item],
      updatedAt: DateTime.now().toUtc(),
    );
    await playlistStore.save(updated);

    return _json({'itemId': item.id}, status: 201);
  });

  router.post('/<id>/sync', (Request request, String id) async {
    final playlist = await playlistStore.findById(id);
    if (playlist == null) return _error('Not found', status: 404);

    JointPlaylist current = playlist;
    final errors = <String>[];
    for (final participantNodeId in playlist.participantNodeIds) {
      final friend = await friendStore.findByNodeId(participantNodeId);
      if (friend == null) {
        errors.add('$participantNodeId is not a known friend');
        continue;
      }
      final path = '/api/v1/sharing/playlists/$id';
      final headers = await RequestSigner(
        identity,
      ).sign(method: 'GET', path: path);
      try {
        // Direct first, falling back to the friend's own reported relay
        // (ADR 0032/0033) if direct reachability fails outright.
        final response = await reachFriend(
          client,
          friend,
          path,
          headers: headers,
        );
        if (response.statusCode != 200) {
          errors.add(
            '$participantNodeId returned ${response.statusCode}: '
            '${response.body}',
          );
          continue;
        }
        final remote = JointPlaylist.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>,
        );
        current = await playlistStore.mergeRemote(remote);
      } catch (e) {
        errors.add('$participantNodeId unreachable: $e');
      }
    }

    return _json({'playlist': current.toJson(), 'errors': errors});
  });

  return router;
}
