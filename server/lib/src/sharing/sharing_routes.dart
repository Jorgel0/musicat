import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../federation/request_signing.dart';
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

/// App-facing routes for managing what *this* node shares.
///
/// Not yet protected beyond "whoever can reach this server can call it" —
/// the same known, deliberate gap ADR 0019/0020 already flagged for early
/// endpoints, growing here to a second one; a general local-API auth
/// mechanism (rather than a one-off fix per endpoint) is worth addressing
/// holistically at some point, not decided in this slice.
Router buildLibraryRouter(SharedTrackStore store) {
  final router = Router();

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
      visibility = SharedTrackVisibility.fromJson(visibilityJson);
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

  return router;
}

/// Federation-facing routes — what a *friend's* server calls to browse and
/// download what's been shared with them. Every route checks
/// [SharedTrackVisibility.allows] on top of [verifiedNodeId]'s "is this
/// even a known, signed-in friend" check.
Router buildSharingFederationRouter(
  SharedTrackStore store,
  RequestVerifier verifier,
) {
  final router = Router();

  router.get('/shared-tracks', (Request request) async {
    final nodeId = await verifiedNodeId(request, verifier);
    if (nodeId == null) {
      return _error('Invalid or missing signature', status: 401);
    }
    final tracks = await store.visibleTo(nodeId);
    return _json([for (final track in tracks) track.toPublicJson()]);
  });

  router.get('/shared-tracks/<id>/file', (Request request, String id) async {
    final nodeId = await verifiedNodeId(request, verifier);
    if (nodeId == null) {
      return _error('Invalid or missing signature', status: 401);
    }

    final track = await store.findById(id);
    if (track == null) return _error('Not found', status: 404);
    if (!track.visibility.allows(nodeId)) {
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
    final nodeId = await verifiedNodeId(request, verifier);
    if (nodeId == null) {
      return _error('Invalid or missing signature', status: 401);
    }

    final track = await store.findById(id);
    if (track == null) return _error('Not found', status: 404);
    if (!track.visibility.allows(nodeId)) {
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
