import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'soulseek_models.dart';

Response _json(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Response _error(String message, {int status = 400}) =>
    _json({'error': message}, status: status);

/// Builds the `/api/v1/soulseek/*` routes: a stable, already-parsed API the
/// app can depend on regardless of which Soulseek backend (today, slskd)
/// sits behind it. See ADR 0016.
Router buildSoulseekRouter(SoulseekGateway gateway) {
  final router = Router();

  router.get('/status', (Request request) async {
    try {
      return _json({'connected': await gateway.isConnected()});
    } on SoulseekGatewayException catch (e) {
      return _gatewayErrorResponse(e);
    }
  });

  router.post('/searches', (Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final query = body['query'];
    if (query is! String || query.isEmpty) {
      return _error('"query" is required');
    }

    try {
      final searchId = await gateway.startSearch(query);
      return _json({'searchId': searchId}, status: 201);
    } on SoulseekGatewayException catch (e) {
      return _gatewayErrorResponse(e);
    }
  });

  router.get('/searches/<id>', (Request request, String id) async {
    try {
      final search = await gateway.getSearch(id);
      return _json(search.toJson());
    } on SoulseekGatewayException catch (e) {
      return _gatewayErrorResponse(e);
    }
  });

  router.delete('/searches/<id>', (Request request, String id) async {
    try {
      await gateway.cancelSearch(id);
      return Response(204);
    } on SoulseekGatewayException catch (e) {
      return _gatewayErrorResponse(e);
    }
  });

  router.post('/downloads', (Request request) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return _error('Request body must be JSON');
    }

    final username = body['username'];
    final filesJson = body['files'];
    if (username is! String || username.isEmpty) {
      return _error('"username" is required');
    }
    if (filesJson is! List || filesJson.isEmpty) {
      return _error('"files" must be a non-empty list');
    }

    try {
      final files = [
        for (final file in filesJson)
          SoulseekFile.fromRequestJson(file as Map<String, dynamic>),
      ];
      await gateway.enqueueDownload(username: username, files: files);
      return Response(201);
    } on SoulseekGatewayException catch (e) {
      return _gatewayErrorResponse(e);
    }
  });

  router.get('/downloads', (Request request) async {
    try {
      final transfers = await gateway.getDownloads();
      return _json([for (final transfer in transfers) transfer.toJson()]);
    } on SoulseekGatewayException catch (e) {
      return _gatewayErrorResponse(e);
    }
  });

  router.delete('/downloads/<username>/<transferId>', (
    Request request,
    String username,
    String transferId,
  ) async {
    try {
      await gateway.cancelDownload(username: username, transferId: transferId);
      return Response(204);
    } on SoulseekGatewayException catch (e) {
      return _gatewayErrorResponse(e);
    }
  });

  router.get('/downloads-directory', (Request request) async {
    final directory = await gateway.getDownloadsDirectory();
    return _json({'directory': directory});
  });

  return router;
}

Response _gatewayErrorResponse(SoulseekGatewayException e) {
  final status = switch (e) {
    SoulseekNotConnectedException() => 409,
    SoulseekUserOfflineException() => 404,
    _ => e.statusCode >= 400 && e.statusCode < 600 ? e.statusCode : 502,
  };
  return _error(e.message, status: status);
}
