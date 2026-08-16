import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/soulseek/slskd_config.dart';
import 'package:musicat_server/src/soulseek/slskd_gateway.dart';
import 'package:musicat_server/src/soulseek/soulseek_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

Response _jsonResponse(Map<String, Object?> body) => Response.ok(
  jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Router _buildRouter(NodeIdentity identity, Router soulseekRouter) {
  return Router()
    ..get('/', (Request req) => _jsonResponse({'status': 'ok'}))
    ..get(
      '/api/v1/node',
      (Request req) => _jsonResponse({'nodeId': identity.nodeId}),
    )
    ..mount('/api/v1/soulseek/', soulseekRouter.call);
}

void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final dataDir = Directory(
    Platform.environment['MUSICAT_DATA_DIR'] ?? './data',
  );

  final identity = await NodeIdentityStore(dataDir).loadOrCreate();
  print('Node identity: ${identity.nodeId}');

  final slskdConfig = SlskdConfig.fromEnvironment(Platform.environment);
  final soulseekRouter = buildSoulseekRouter(SlskdGateway(config: slskdConfig));

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(_buildRouter(identity, soulseekRouter).call);

  final server = await serve(handler, ip, port);
  print('Server listening on port ${server.port}');
}
