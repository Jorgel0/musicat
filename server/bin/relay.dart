import 'dart:io';

import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';

/// Standalone entry point for the self-hosted relay fallback (ADR 0032/0033)
/// -- deployed separately from any user's own Musicat Server, on a host
/// with genuine public reachability. Two friends whose Musicat Servers
/// can't reach each other directly (NAT hole-punching didn't work, no
/// port-forward) can each open an *outbound* connection here instead.
void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8090');

  final hub = RelayHub();
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(hub.buildRouter().call);

  final server = await serve(handler, ip, port);
  print('Musicat relay listening on port ${server.port}');
}
