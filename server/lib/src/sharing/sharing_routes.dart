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
import 'joint_playlist_store.dart';
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

/// Rewrites every id in [visibility] to the friend **account** it names,
/// resolving whatever the app happened to hand over (an account id, or any
/// of that friend's device nodeIds) through [friendStore].
///
/// This is what keeps [SharedTrackVisibility]'s account-only comparison
/// from quietly locking a multi-device friend out of a track meant for
/// them: rules are normalized once, here at the write boundary, instead of
/// widening the read-side check to also accept device nodeIds (which would
/// hand access to whichever account a device has since moved to). An id
/// that resolves to no known friend is stored unchanged — it simply never
/// matches anyone, which is the safe direction.
Future<SharedTrackVisibility> resolveVisibilityAccounts(
  SharedTrackVisibility visibility,
  FriendStore friendStore,
) async {
  if (visibility is! FriendsVisibility) return visibility;
  final resolved = <String>{};
  for (final id in visibility.accountIds) {
    final friend = await friendStore.findByAccountOrDeviceId(id);
    resolved.add(friend?.accountId ?? id);
  }
  return FriendsVisibility(resolved);
}

/// App-facing routes for managing what *this* node shares, and for
/// browsing/downloading what a friend has shared back (ADR 0029) — the app
/// itself never holds this node's signing key, so any call to a friend's
/// `/api/v1/sharing/*` has to be proxied through this server, which does
/// the actual signing.
///
/// Not yet protected beyond "whoever can reach this server can call it" —
/// the same known, deliberate gap ADR 0019/0020 already flagged for early
/// endpoints, growing here to a second one; a general local-API auth
/// mechanism (rather than a one-off fix per endpoint) is worth addressing
/// holistically at some point, not decided in this slice.
Router buildLibraryRouter(
  SharedTrackStore store,
  FriendStore friendStore,
  NodeIdentity identity, {
  http.Client? httpClient,
}) {
  final router = Router();
  final client = httpClient ?? http.Client();

  router.post('/shared-tracks', (Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final filePath = body['filePath'];
    final title = body['title'];
    final artist = body['artist'];
    final visibilityJson = body['visibility'];
    if (filePath is! String || filePath.isEmpty) {
      return _error('"filePath" is required');
    }
    if (title is! String || title.isEmpty) {
      return _error('"title" is required');
    }
    if (artist is! String || artist.isEmpty) {
      return _error('"artist" is required');
    }
    if (visibilityJson is! Map<String, dynamic>) {
      return _error('"visibility" is required');
    }
    if (!File(filePath).existsSync()) {
      return _error('File not found: $filePath', status: 404);
    }

    final SharedTrackVisibility visibility;
    try {
      visibility = await resolveVisibilityAccounts(
        SharedTrackVisibility.fromJson(visibilityJson),
        friendStore,
      );
    } on FormatException catch (e) {
      return _error(e.message);
    }

    final track = SharedTrack(
      id: _generateId(),
      filePath: filePath,
      title: title,
      artist: artist,
      album: body['album'] as String?,
      coverArtPath: body['coverArtPath'] as String?,
      visibility: visibility,
    );
    await store.add(track);
    return _json({'id': track.id}, status: 201);
  });

  router.get('/shared-tracks', (Request request) async {
    final tracks = await store.loadAll();
    return _json([for (final track in tracks) track.toStorageJson()]);
  });

  router.delete('/shared-tracks/<id>', (Request request, String id) async {
    await store.remove(id);
    return Response(204);
  });

  // <friendId> is whatever id this device's own app holds for the friend:
  // their accountId, or (as every id stored before Fase 5 is) one of their
  // device nodeIds. Both resolve to the same friend account.
  router.get('/friends/<friendId>/shared-tracks', (
    Request request,
    String friendId,
  ) async {
    final friend = await friendStore.findByAccountOrDeviceId(friendId);
    if (friend == null) return _error('Unknown friend', status: 404);

    const path = '/api/v1/sharing/shared-tracks';
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
      // Forward the friend's own status/body as-is (already a JSON
      // {"error": ...} shape on failure) rather than re-wrapping it inside
      // another {"error": ...} envelope.
      return Response(
        response.statusCode,
        body: response.body,
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return _error('Friend unreachable: $e', status: 502);
    }
  });

  Future<Response> proxyFriendFile(
    String friendId,
    String trackId,
    String suffix,
    String defaultContentType,
  ) async {
    final friend = await friendStore.findByAccountOrDeviceId(friendId);
    if (friend == null) return _error('Unknown friend', status: 404);

    final path = '/api/v1/sharing/shared-tracks/$trackId/$suffix';
    final headers = await RequestSigner(
      identity,
    ).sign(method: 'GET', path: path);
    try {
      final friendResponse = await reachFriendStreamed(
        client,
        friend,
        path,
        headers: headers,
      );
      if (friendResponse.statusCode != 200) {
        final body = await friendResponse.stream.bytesToString();
        return Response(
          friendResponse.statusCode,
          body: body,
          headers: {'content-type': 'application/json'},
        );
      }
      return Response.ok(
        friendResponse.stream,
        headers: {
          'content-type':
              friendResponse.headers['content-type'] ?? defaultContentType,
        },
      );
    } catch (e) {
      return _error('Friend unreachable: $e', status: 502);
    }
  }

  router.get(
    '/friends/<friendId>/shared-tracks/<id>/file',
    (Request request, String friendId, String id) =>
        proxyFriendFile(friendId, id, 'file', 'application/octet-stream'),
  );

  router.get(
    '/friends/<friendId>/shared-tracks/<id>/cover',
    (Request request, String friendId, String id) =>
        proxyFriendFile(friendId, id, 'cover', 'image/jpeg'),
  );

  return router;
}

/// Federation-facing routes — what a *friend's* server calls to browse and
/// download what's been shared with them, and (for joint playlists, ADR
/// 0026) to fetch this node's current view for merging into their own.
/// Every route checks an object-level authz rule on top of
/// [verifiedFriendAccountId]'s "is this even a known, signed-in friend"
/// check — [SharedTrackVisibility.allows] for tracks, playlist membership
/// for playlists. Both of those compare the caller's verified friend
/// **account** id, never the nodeId of whichever of that account's devices
/// happened to sign: any of a friend's devices is that friend.
///
/// Both live under the same `/api/v1/sharing/` prefix and the same
/// `Router` instance deliberately: mounting two separately-built routers
/// at the *same* prefix would have the first one's wildcard swallow every
/// request before the second ever got a chance (see ADR 0025's note on
/// `/api/v1/federation/` vs `/api/v1/sharing/` for the same reasoning).
Router buildSharingFederationRouter(
  SharedTrackStore store,
  JointPlaylistStore playlistStore,
  RequestVerifier verifier,
) {
  final router = Router();

  router.get('/playlists/<id>', (Request request, String id) async {
    final accountId = await verifiedFriendAccountId(request, verifier);
    if (accountId == null) {
      return _error('Invalid or missing signature', status: 401);
    }

    final playlist = await playlistStore.findById(id);
    if (playlist == null) return _error('Not found', status: 404);
    if (!playlist.participantAccountIds.contains(accountId)) {
      return _error('Not a participant in this playlist', status: 403);
    }

    return _json(playlist.toJson());
  });

  router.get('/shared-tracks', (Request request) async {
    final accountId = await verifiedFriendAccountId(request, verifier);
    if (accountId == null) {
      return _error('Invalid or missing signature', status: 401);
    }
    final tracks = await store.visibleTo(accountId);
    return _json([for (final track in tracks) track.toPublicJson()]);
  });

  router.get('/shared-tracks/<id>/file', (Request request, String id) async {
    final accountId = await verifiedFriendAccountId(request, verifier);
    if (accountId == null) {
      return _error('Invalid or missing signature', status: 401);
    }

    final track = await store.findById(id);
    if (track == null) return _error('Not found', status: 404);
    if (!track.visibility.allows(accountId)) {
      return _error('Not shared with you', status: 403);
    }

    final file = File(track.filePath);
    if (!file.existsSync()) {
      return _error('File no longer available', status: 404);
    }
    return Response.ok(
      file.openRead(),
      headers: {'content-type': 'application/octet-stream'},
    );
  });

  router.get('/shared-tracks/<id>/cover', (Request request, String id) async {
    final accountId = await verifiedFriendAccountId(request, verifier);
    if (accountId == null) {
      return _error('Invalid or missing signature', status: 401);
    }

    final track = await store.findById(id);
    if (track == null) return _error('Not found', status: 404);
    if (!track.visibility.allows(accountId)) {
      return _error('Not shared with you', status: 403);
    }

    final coverPath = track.coverArtPath;
    if (coverPath == null || !File(coverPath).existsSync()) {
      return _error('No cover art', status: 404);
    }
    return Response.ok(
      File(coverPath).openRead(),
      headers: {'content-type': 'image/jpeg'},
    );
  });

  return router;
}
