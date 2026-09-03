/// Where this device reaches its own Musicat Server for federation
/// (friends/pairing — server ADR 0019/0020), and what to tell a friend so
/// *their* server can reach this one back.
///
/// [host]/[port] are this class's own idea of where to reach the server —
/// meaningful as-is only when [useEmbeddedServer] is `false` (a separately
/// self-hosted server: NAS, VPS, Docker Compose). When [useEmbeddedServer]
/// is `true`, the *effective* host/port actually used by the app comes
/// from the running embedded server instead (Linux, Windows, or Android —
/// see `core/embedded_server/embedded_server.dart`), not from these fields;
/// see `effectiveMusicatServerConfigProvider`
/// (`musicat_server_config_controller.dart`) for that substitution. This
/// class itself stays a dumb, Riverpod-unaware value — it doesn't know
/// about the embedded server at all, so [host]/[port] here are always
/// whatever was last manually entered (or the constructor defaults),
/// preserved untouched so switching [useEmbeddedServer] back off restores
/// them exactly as they were.
class MusicatServerConfig {
  const MusicatServerConfig({
    required this.host,
    required this.port,
    required this.myPublicAddress,
    this.myDisplayName,
    this.useEmbeddedServer = false,
    this.apiKey,
    this.relayUrl,
  });

  /// How this app reaches its own Musicat Server (e.g. `localhost`) when
  /// [useEmbeddedServer] is `false`. Ignored (but preserved) otherwise.
  final String host;
  final int port;

  /// `host:port` to give a friend so their server can reach this node —
  /// not necessarily the same as [host]/[port] above (e.g. a port-forward
  /// or dynamic DNS name a friend on a different network would need,
  /// versus how this device reaches its own, likely local, server). See
  /// ADR 0021: making this reachable at all is on the user for now.
  /// Applies the same whether [useEmbeddedServer] is on or off.
  final String myPublicAddress;

  /// This device's own display name, sent automatically as `displayName`
  /// whenever [FriendsController.addFriend] redeems a friend's code — the
  /// name *they'll* see for this node in their own friends list. `null`
  /// until the user sets one (nothing is sent in that case either).
  final String? myDisplayName;

  /// When `true`, this device uses its own embedded Musicat Server
  /// (started at app bootstrap — directly in-process on Linux/Windows, or
  /// inside a real Android background service, see
  /// `core/embedded_server/embedded_server.dart`) instead of [host]/[port]
  /// above — the common case, needing no manual setup at all. Defaults to
  /// `false` here (a "nothing configured" baseline, e.g. [empty], or any
  /// platform embedding isn't supported on); the platform-aware "default
  /// to `true` on a fresh install where embedding is supported" choice is
  /// made by `loadMusicatServerConfigPreference`, the one call site that
  /// actually knows whether this is a fresh install.
  final bool useEmbeddedServer;

  /// This operator's shared secret for a genuinely remote, self-hosted
  /// server ([useEmbeddedServer] `false`) that's configured to require one
  /// (`MUSICAT_APP_API_KEY` server-side — see
  /// `server/lib/src/http/require_local.dart`). Sent as the `X-Api-Key`
  /// header on every call this device makes to its own configured server.
  /// `null`/empty (the default, and always the case for the embedded
  /// server, which never populates this field) means no header is sent —
  /// fine for the embedded server (always loopback) and for a remote
  /// server that hasn't opted into requiring the key.
  final String? apiKey;

  /// A self-hosted relay fallback (server ADR 0032/0033) for this device's
  /// own *embedded* server to connect out to at startup, so it stays
  /// reachable by a friend on a genuinely different network (not just this
  /// device's own LAN) when direct NAT hole-punching doesn't work for that
  /// pair of networks -- the same role the CLI/self-hosting path's own
  /// `MUSICAT_RELAY_URL` environment variable already plays (ADR 0035).
  /// `null`/empty (the default) means no relay is configured; this project
  /// has no baked-in default relay of its own to point at -- self-hosting
  /// one is on the user, same as for a manually self-hosted server.
  /// Ignored (but preserved) when [useEmbeddedServer] is `false`: a
  /// manually-configured remote server sets its own relay independently,
  /// through its own environment, not through this app.
  ///
  /// Only takes effect the *next* time the embedded server starts (i.e.
  /// after restarting the app) -- see `embeddedServerProvider`'s own doc
  /// comment (`core/embedded_server/embedded_server.dart`) for why editing
  /// this deliberately never restarts an already-running embedded server.
  final String? relayUrl;

  bool get isConfigured => host.isNotEmpty;

  String get baseUrl => 'http://$host:$port';

  MusicatServerConfig copyWith({
    String? host,
    int? port,
    String? myPublicAddress,
    String? myDisplayName,
    bool? useEmbeddedServer,
    String? apiKey,
    String? relayUrl,
  }) => MusicatServerConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    myPublicAddress: myPublicAddress ?? this.myPublicAddress,
    myDisplayName: myDisplayName ?? this.myDisplayName,
    useEmbeddedServer: useEmbeddedServer ?? this.useEmbeddedServer,
    apiKey: apiKey ?? this.apiKey,
    relayUrl: relayUrl ?? this.relayUrl,
  );

  static const empty = MusicatServerConfig(
    host: '',
    port: 8080,
    myPublicAddress: '',
  );
}
