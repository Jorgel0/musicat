import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

import 'src/federation/federation_routes.dart';
import 'src/federation/friend_store.dart';
import 'src/federation/pairing_code_store.dart';
import 'src/federation/request_signing.dart';
import 'src/http/require_local.dart';
import 'src/identity/node_identity.dart';
import 'src/nat/udp_puncher.dart';
import 'src/relay/relay_client.dart';
import 'src/sharing/joint_playlist_store.dart';
import 'src/sharing/playlist_routes.dart';
import 'src/sharing/shared_track_store.dart';
import 'src/sharing/sharing_routes.dart';
import 'src/soulseek/slskd_config.dart';
import 'src/soulseek/slskd_gateway.dart';
import 'src/soulseek/soulseek_routes.dart';

/// A running Musicat Server instance, as returned by [startMusicatServer].
///
/// Bundles what a caller embedding the server in-process (the Flutter app
/// itself, see ADR 0040/0041) needs in order to introspect it or shut it
/// down cleanly: the resolved [identity], the HTTP [port] actually bound
/// (meaningful when [startMusicatServer] was called with `port: 0`, i.e.
/// "let the OS pick one"), and whatever relay-connection outcome was
/// reached ([relayUrl]).
class MusicatServerHandle {
  MusicatServerHandle._({
    required this.identity,
    required this.publicKeyBase64,
    required this.port,
    required this.relayUrl,
    required this._httpServer,
    required this._relayClient,
    required this._puncher,
  });

  /// This node's persistent cryptographic identity (ADR 0015: stable across
  /// restarts as long as the same `dataDir` is reused).
  final NodeIdentity identity;

  /// [identity]'s public key, base64-encoded -- the same value the
  /// `/api/v1/node` route reports.
  final String publicKeyBase64;

  /// The HTTP port this server is actually bound to and serving requests
  /// on. This is the real OS-assigned port when [startMusicatServer] was
  /// called with `port: 0`, never the literal `0` that was passed in.
  final int port;

  /// The relay URL advertised to friends at pairing time, or `null` if
  /// either no relay was configured for this run, or the configured one
  /// couldn't be reached at startup (see [startMusicatServer]'s `relayUrl`
  /// parameter).
  final String? relayUrl;

  final HttpServer _httpServer;
  final RelayClient? _relayClient;
  final UdpPuncher _puncher;

  /// Shuts down everything [startMusicatServer] started: the relay tunnel
  /// (if one was connected), the UDP hole-punching socket, and the HTTP
  /// server itself. Safe to call even if no relay was ever connected. A
  /// request made against [port] after this completes will fail to
  /// connect.
  Future<void> close() async {
    await _relayClient?.close();
    await _puncher.close();
    await _httpServer.close(force: true);
  }
}

Response _jsonResponse(Map<String, Object?> body) => Response.ok(
  jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

Router _buildRouter(
  NodeIdentity identity,
  String publicKeyBase64,
  String? myRelayUrl,
  Router soulseekRouter,
  Router federationRouter,
  Router libraryRouter,
  Router playlistRouter,
  Router sharingFederationRouter, {
  String? appApiKey,
}) {
  return Router()
    ..get('/', (Request req) => _jsonResponse({'status': 'ok'}))
    ..get(
      '/api/v1/node',
      (Request req) => _jsonResponse({
        'nodeId': identity.nodeId,
        'publicKeyBase64': publicKeyBase64,
        'relayUrl': myRelayUrl,
      }),
    )
    // soulseek/library/playlists are entirely app-facing (this device's own
    // app talking to its own local server) -- wrapped in requireLocal()
    // here, at the mount site, rather than touching every individual route
    // inside those routers. sharingFederationRouter and the bulk of
    // federationRouter are deliberately left unwrapped: they're what a
    // friend's server calls, and must stay reachable over the real network
    // (see require_local.dart's doc comment). federationRouter wraps its
    // own handful of app-facing routes internally -- see
    // buildFederationRouter's doc comment in federation_routes.dart.
    ..mount(
      '/api/v1/soulseek/',
      requireLocal(soulseekRouter.call, appApiKey: appApiKey),
    )
    ..mount('/api/v1/federation/', federationRouter.call)
    // Each of these is a sibling of /api/v1/federation/, not nested under
    // it: shelf_router's mount() matches on prefix in registration order
    // with no most-specific-first resolution, so a route actually nested
    // under an already-mounted prefix would silently never be reached --
    // the parent mount's wildcard would swallow it first.
    ..mount('/api/v1/sharing/', sharingFederationRouter.call)
    ..mount(
      '/api/v1/library/',
      requireLocal(libraryRouter.call, appApiKey: appApiKey),
    )
    // No trailing slash here, unlike the mounts above: buildPlaylistRouter
    // has a genuine bare-collection route ('/', for create/list) and
    // shelf_router's mount() only matches a bare `/api/v1/playlists`
    // request (no trailing slash) when the prefix itself is given without
    // one -- with a trailing slash, only `/api/v1/playlists/<anything>`
    // (note the required slash) would ever match.
    ..mount(
      '/api/v1/playlists',
      requireLocal(playlistRouter.call, appApiKey: appApiKey),
    );
}

/// Starts a full Musicat Server: loads/creates this node's identity from
/// [dataDir], binds NAT hole-punching, optionally connects to a relay
/// fallback, wires up every router (federation, sharing, library,
/// playlists, soulseek), and starts serving HTTP on [port].
///
/// This is the single production entry point both `bin/server.dart` (the
/// CLI/Docker/self-hosting path) and the Flutter app (embedding the server
/// in-process, see ADR 0040/0041) call -- the exact same code runs either
/// way, so there is only ever one server implementation to trust.
///
/// [port]: the HTTP port to serve on; `0` lets the OS assign one (see
/// [MusicatServerHandle.port] for how to read back which one it picked).
/// [udpPort]: the local UDP port for NAT hole-punching; `0` (the default)
/// lets the OS assign one, same as [UdpPuncher.bind] already does.
/// [relayUrl]: a self-hosted relay fallback (ADR 0032/0033) to connect out
/// to, for when NAT hole-punching doesn't work for a given pair of
/// networks; connecting is opt-in and best-effort -- omit or leave empty
/// to run without one.
/// [slskdConfig]: connection settings for the slskd instance this server
/// wraps; defaults to [SlskdConfig.fromEnvironment] of an empty
/// environment (`localhost:5030`, no API key), which behaves gracefully
/// when Soulseek isn't configured at all -- the embedded-in-the-app use
/// case may well not have it set up yet, especially on Android.
/// [onLog]: called with the same operator-facing status lines the CLI has
/// always printed (identity, NAT candidate, relay status, listening port)
/// -- omit it (the default) to run silently, which is what an in-process
/// embedding wants; `bin/server.dart` passes `print`.
/// [appApiKey]: an operator-configured shared secret (`MUSICAT_APP_API_KEY`)
/// that lets a non-loopback caller reach the app-facing routes this server
/// would otherwise restrict to its own device -- the explicit opt-in for
/// genuinely remote, intentionally self-hosted setups (`docs/
/// self-hosting.md`); see `requireLocal`'s own doc comment
/// (`src/http/require_local.dart`) for exactly how it's checked. Omit or
/// leave empty (the default) to keep today's loopback-only behavior --
/// what the embedded-in-the-app case (ADR 0040/0041) always wants, since
/// it's always loopback and never needs this at all.
Future<MusicatServerHandle> startMusicatServer({
  required Directory dataDir,
  int port = 8080,
  int udpPort = 0,
  String? relayUrl,
  SlskdConfig? slskdConfig,
  void Function(String message)? onLog,
  String? appApiKey,
}) async {
  final ip = InternetAddress.anyIPv4;
  final log = onLog ?? (String message) {};

  final identity = await NodeIdentityStore(dataDir).loadOrCreate();
  final publicKeyBase64 = await identity.publicKeyBase64();
  log('Node identity: ${identity.nodeId}');

  final effectiveSlskdConfig =
      slskdConfig ?? SlskdConfig.fromEnvironment(const {});
  final soulseekRouter = buildSoulseekRouter(
    SlskdGateway(config: effectiveSlskdConfig),
  );

  final friendStore = FriendStore(dataDir);
  final puncher = UdpPuncher(identity: identity, friendStore: friendStore);
  final boundUdpPort = await puncher.bind(port: udpPort);
  final candidate = await puncher.refreshCandidate();
  log(
    'NAT traversal: listening for UDP punches on port $boundUdpPort '
    '(external candidate: ${candidate ?? "unknown — STUN unreachable"})',
  );

  // Self-hosted relay fallback (ADR 0032/0033) for when NAT hole-punching
  // above doesn't work for a given pair of networks -- opt-in, since it
  // requires a separately-deployed relay instance with real public
  // reachability. Connecting is best-effort: a friend request can still
  // arrive directly even if this node has no relay configured, or if the
  // configured one is unreachable right now. Attempted *before* the
  // federation router is built, since a successful connection is what
  // gets advertised to friends at pairing time (`myRelayUrl` below) --
  // `RelayClient` itself needs the final request handler to service
  // tunneled requests, which doesn't exist yet this early, so it's given
  // a forwarding closure that's only ever invoked once a real request
  // arrives, by which point `_handler` has been assigned for real.
  Handler? realHandler;
  Future<Response> forwardToRealHandler(Request request) async =>
      realHandler!(request);

  String? myRelayUrl;
  RelayClient? relayClient;
  if (relayUrl != null && relayUrl.isNotEmpty) {
    relayClient = RelayClient(
      identity: identity,
      localHandler: forwardToRealHandler,
    );
    final connected = await relayClient.connect(relayUrl);
    if (connected) {
      myRelayUrl = relayUrl;
      log(
        'Relay: connected to $relayUrl as a fallback for direct reachability',
      );
    } else {
      log('Relay: could not connect to $relayUrl (continuing without it)');
    }
  }

  final federationRouter = buildFederationRouter(
    friendStore,
    RequestVerifier(friendStore),
    PairingCodeStore(),
    puncher,
    myRelayUrl: myRelayUrl,
    appApiKey: appApiKey,
  );

  final sharedTrackStore = SharedTrackStore(dataDir);
  final playlistStore = JointPlaylistStore(dataDir);
  final libraryRouter = buildLibraryRouter(
    sharedTrackStore,
    friendStore,
    identity,
  );
  final playlistRouter = buildPlaylistRouter(
    playlistStore,
    sharedTrackStore,
    friendStore,
    identity,
  );
  final sharingFederationRouter = buildSharingFederationRouter(
    sharedTrackStore,
    playlistStore,
    RequestVerifier(friendStore),
  );

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(
        _buildRouter(
          identity,
          publicKeyBase64,
          myRelayUrl,
          soulseekRouter,
          federationRouter,
          libraryRouter,
          playlistRouter,
          sharingFederationRouter,
          appApiKey: appApiKey,
        ).call,
      );
  realHandler = handler;

  final server = await serve(handler, ip, port);
  log('Server listening on port ${server.port}');

  return MusicatServerHandle._(
    identity: identity,
    publicKeyBase64: publicKeyBase64,
    port: server.port,
    relayUrl: myRelayUrl,
    httpServer: server,
    relayClient: relayClient,
    puncher: puncher,
  );
}
