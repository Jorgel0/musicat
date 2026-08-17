import 'dart:convert';
import 'dart:io';

import 'package:musicat_server/src/federation/federation_routes.dart';
import 'package:musicat_server/src/federation/friend_store.dart';
import 'package:musicat_server/src/federation/pairing_code_store.dart';
import 'package:musicat_server/src/federation/request_signing.dart';
import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:musicat_server/src/nat/udp_puncher.dart';
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

Router _buildRouter(
  NodeIdentity identity,
  String publicKeyBase64,
  Router soulseekRouter,
  Router federationRouter,
) {
  return Router()
    ..get('/', (Request req) => _jsonResponse({'status': 'ok'}))
    ..get(
      '/api/v1/node',
      (Request req) => _jsonResponse({
        'nodeId': identity.nodeId,
        'publicKeyBase64': publicKeyBase64,
      }),
    )
    ..mount('/api/v1/soulseek/', soulseekRouter.call)
    ..mount('/api/v1/federation/', federationRouter.call);
}

void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final dataDir = Directory(
    Platform.environment['MUSICAT_DATA_DIR'] ?? './data',
  );

  final identity = await NodeIdentityStore(dataDir).loadOrCreate();
  final publicKeyBase64 = await identity.publicKeyBase64();
  print('Node identity: ${identity.nodeId}');

  final slskdConfig = SlskdConfig.fromEnvironment(Platform.environment);
  final soulseekRouter = buildSoulseekRouter(SlskdGateway(config: slskdConfig));

  final friendStore = FriendStore(dataDir);
  final puncher = UdpPuncher(identity: identity, friendStore: friendStore);
  final udpPort = await puncher.bind(
    port: int.tryParse(Platform.environment['MUSICAT_UDP_PORT'] ?? '') ?? 0,
  );
  final candidate = await puncher.refreshCandidate();
  print(
    'NAT traversal: listening for UDP punches on port $udpPort '
    '(external candidate: ${candidate ?? "unknown — STUN unreachable"})',
  );

  final federationRouter = buildFederationRouter(
    friendStore,
    RequestVerifier(friendStore),
    PairingCodeStore(),
    puncher,
  );

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(
        _buildRouter(
          identity,
          publicKeyBase64,
          soulseekRouter,
          federationRouter,
        ).call,
      );

  final server = await serve(handler, ip, port);
  print('Server listening on port ${server.port}');
}
