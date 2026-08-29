import 'dart:io';

import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';

/// Standalone entry point for the self-hosted relay fallback (ADR 0032/0033)
/// -- deployed separately from any user's own Musicat Server, on a host
/// with genuine public reachability. Two friends whose Musicat Servers
/// can't reach each other directly (NAT hole-punching didn't work, no
/// port-forward) can each open an *outbound* connection here instead.
///
/// `MUSICAT_RELAY_DATA_DIR` (default `./data`, mirroring the main server's
/// own `MUSICAT_DATA_DIR` convention) is where the username directory
/// (nodes claiming a friendly, memorable pointer to their own nodeId) is
/// persisted -- back this with a volume in production, same as the main
/// server's own data directory, or claims won't survive a restart.
void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8090');
  final dataDir = Directory(
    Platform.environment['MUSICAT_RELAY_DATA_DIR'] ?? './data',
  );

  final hub = RelayHub(dataDir: dataDir);
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(hub.buildRouter().call);

  final server = await serve(handler, ip, port);
  print('Musicat relay listening on port ${server.port}');
}
