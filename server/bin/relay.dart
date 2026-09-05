import 'dart:io';

import 'package:musicat_server/src/accounts/account_routes.dart';
import 'package:musicat_server/src/accounts/account_store.dart';
import 'package:musicat_server/src/accounts/friend_request_store.dart';
import 'package:musicat_server/src/relay/relay_hub.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

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
///
/// Also hosts the portable account service (Fase 5, `/accounts/*` --
/// `src/accounts/account_routes.dart`) on this same deployed process/port,
/// under its own distinct `/accounts` prefix, mounted *before* [RelayHub]'s
/// own router below: shelf_router matches mounted prefixes in registration
/// order with no most-specific-first resolution (see the same note in
/// `musicat_server_runtime.dart`), and [RelayHub]'s own catch-all forwarding
/// route (`/<nodeId>/<path>`) would otherwise happily treat "accounts" as a
/// literal nodeId. `accounts.json`/`friend_requests.json` are persisted
/// into the same [dataDir] as the username directory -- a categorically
/// more sensitive one (it holds password hashes), which is exactly why the
/// account service is its own module (`AccountStore`/`FriendRequestStore`)
/// rather than folded into [RelayHub] itself, even though it shares a data
/// directory and an HTTP port with it.
///
/// Because the two *are* in one process, the account service is handed the
/// hub as its [DeviceNotifier] -- a one-method capability, not the hub
/// itself in any broader sense (see that interface's doc comment) -- so
/// accepting a friend request can nudge the other side's devices over the
/// tunnels they already hold open, instead of leaving them to find out on
/// their next poll. That nudge deliberately carries no data at all: see
/// [RelayNotify]. This is the only wire between the two modules, and it
/// points one way.
void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8090');
  final dataDir = Directory(
    Platform.environment['MUSICAT_RELAY_DATA_DIR'] ?? './data',
  );

  final hub = RelayHub(dataDir: dataDir);
  final accountStore = AccountStore(dataDir);
  final friendRequestStore = FriendRequestStore(dataDir);
  final accountRouter = buildAccountRouter(
    accountStore,
    friendRequestStore,
    deviceNotifier: hub,
  );

  final router = Router()
    ..mount('/accounts/', accountRouter.call)
    ..mount('/', hub.buildRouter().call);

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router.call);

  final server = await serve(handler, ip, port);
  print('Musicat relay listening on port ${server.port}');
}
