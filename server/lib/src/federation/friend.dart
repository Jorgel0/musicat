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
  });

  final String nodeId;
  final String publicKeyBase64;

  /// `host:port` this node reaches the friend at.
  final String address;
  final String? displayName;

  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'publicKeyBase64': publicKeyBase64,
    'address': address,
    'displayName': displayName,
  };

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
    nodeId: json['nodeId'] as String,
    publicKeyBase64: json['publicKeyBase64'] as String,
    address: json['address'] as String,
    displayName: json['displayName'] as String?,
  );
}
