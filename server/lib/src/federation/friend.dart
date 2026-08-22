/// A trusted remote Musicat Server node.
///
/// [nodeId]/[publicKeyBase64] are how incoming requests claiming to be this
/// friend are verified (see `request_signing.dart`); [address] is where
/// this node itself sends outgoing requests *to* that friend.
class Friend {
  const Friend({
    required this.nodeId,
    required this.publicKeyBase64,
    required this.address,
    this.displayName,
    this.udpCandidate,
    this.relayUrl,
  });

  final String nodeId;
  final String publicKeyBase64;

  /// `host:port` this node reaches the friend at.
  final String address;
  final String? displayName;

  /// `host:port` this friend's own external UDP mapping was last seen as
  /// (via STUN, ADR 0022), if known — the target for a NAT hole-punch
  /// attempt (ADR 0023). Not necessarily still valid: NAT mappings expire,
  /// and this is only ever as fresh as the last pairing/reconnect attempt.
  final String? udpCandidate;

  /// This friend's own relay WebSocket endpoint (e.g.
  /// `ws://relay.example.com/connect`), if they reported one at pairing
  /// time — the fallback address for reaching them when [address] itself
  /// isn't (ADR 0032/0033): a request to it becomes
  /// `<relayUrl's http(s) origin>/<nodeId>/<path>` instead of
  /// `http://$address/<path>`. `null` if they didn't configure a relay.
  final String? relayUrl;

  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'publicKeyBase64': publicKeyBase64,
    'address': address,
    'displayName': displayName,
    'udpCandidate': udpCandidate,
    'relayUrl': relayUrl,
  };

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
    nodeId: json['nodeId'] as String,
    publicKeyBase64: json['publicKeyBase64'] as String,
    address: json['address'] as String,
    displayName: json['displayName'] as String?,
    udpCandidate: json['udpCandidate'] as String?,
    relayUrl: json['relayUrl'] as String?,
  );
}
