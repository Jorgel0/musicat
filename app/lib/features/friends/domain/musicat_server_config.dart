/// Where this device reaches its own Musicat Server for federation
/// (friends/pairing — server ADR 0019/0020), and what to tell a friend so
/// *their* server can reach this one back.
class MusicatServerConfig {
  const MusicatServerConfig({
    required this.host,
    required this.port,
    required this.myPublicAddress,
    this.myDisplayName,
  });

  /// How this app reaches its own Musicat Server (e.g. `localhost`).
  final String host;
  final int port;

  /// `host:port` to give a friend so their server can reach this node —
  /// not necessarily the same as [host]/[port] above (e.g. a port-forward
  /// or dynamic DNS name a friend on a different network would need,
  /// versus how this device reaches its own, likely local, server). See
  /// ADR 0021: making this reachable at all is on the user for now.
  final String myPublicAddress;

  /// This device's own display name, sent automatically as `displayName`
  /// whenever [FriendsController.addFriend] redeems a friend's code — the
  /// name *they'll* see for this node in their own friends list. `null`
  /// until the user sets one (nothing is sent in that case either).
  final String? myDisplayName;

  bool get isConfigured => host.isNotEmpty;

  String get baseUrl => 'http://$host:$port';

  static const empty = MusicatServerConfig(
    host: '',
    port: 8080,
    myPublicAddress: '',
  );
}
