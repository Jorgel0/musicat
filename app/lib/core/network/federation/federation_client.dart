import 'package:dio/dio.dart';

/// This device's own node identity, as reported by its Musicat Server.
class MyNodeInfo {
  const MyNodeInfo({
    required this.nodeId,
    required this.publicKeyBase64,
    this.relayUrl,
  });

  final String nodeId;
  final String publicKeyBase64;

  /// This node's own relay, if its server is actually connected to one
  /// right now (ADR 0032/0033) — worth telling a friend about at pairing
  /// time as a fallback for when [address] isn't directly reachable.
  final String? relayUrl;
}

/// A trusted friend node, as this device's Musicat Server knows it.
class FederationFriend {
  const FederationFriend({
    required this.nodeId,
    required this.publicKeyBase64,
    required this.address,
    this.displayName,
    this.relayUrl,
    this.localNickname,
  });

  final String nodeId;
  final String publicKeyBase64;
  final String address;

  /// The name this friend chose for *themselves* (sent as `displayName` on
  /// their own [addFriend] call) — not a label chosen by this device's own
  /// user. See [localNickname] for that.
  final String? displayName;

  /// This friend's own relay, as reported when they were added (`null` if
  /// they didn't have one connected at that time).
  final String? relayUrl;

  /// A purely local label this device's own user chose for this friend,
  /// via [FederationClient.setLocalNickname] — never sent to, or seen by,
  /// the friend it labels. `null` until set.
  final String? localNickname;

  /// The name to actually show for this friend: [localNickname] (what
  /// this device's user chose to call them) if set, else [displayName]
  /// (what they call themselves), else the raw [nodeId] as a last resort.
  String get displayLabel => localNickname ?? displayName ?? nodeId;

  factory FederationFriend.fromJson(Map<String, dynamic> json) =>
      FederationFriend(
        nodeId: json['nodeId'] as String,
        publicKeyBase64: json['publicKeyBase64'] as String,
        address: json['address'] as String,
        displayName: json['displayName'] as String?,
        relayUrl: json['relayUrl'] as String?,
        localNickname: json['localNickname'] as String?,
      );
}

class FriendConnectionStatus {
  const FriendConnectionStatus({required this.connected, this.lastSeen});

  final bool connected;
  final DateTime? lastSeen;

  factory FriendConnectionStatus.fromJson(Map<String, dynamic> json) =>
      FriendConnectionStatus(
        connected: json['connected'] as bool,
        lastSeen: json['lastSeen'] != null
            ? DateTime.parse(json['lastSeen'] as String)
            : null,
      );
}

class FederationClientException implements Exception {
  const FederationClientException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'FederationClientException($statusCode, $message)';
}

/// Talks to *this device's own* Musicat Server for federation management
/// — friends and pairing (server ADR 0019/0020). Not the same concern as
/// [SoulseekClient]/`MusicatServerSoulseekClient` (ADR 0017), even though
/// both ultimately point at the same running Musicat Server instance.
class FederationClient {
  /// [apiKey], when non-null and non-empty, is sent as `X-Api-Key` on every
  /// call this makes to [baseUrl] — this device's own server. Only ever
  /// meaningful for a genuinely remote, self-hosted server configured to
  /// require it (see `server/lib/src/http/require_local.dart`); `null` or
  /// empty (the default) sends no such header. Deliberately never applied
  /// to [addFriend]'s own separate, non-injectable `Dio` pointed at a
  /// *friend's* server — that call is federation-facing and has its own,
  /// unrelated auth via the pairing code itself.
  FederationClient({required String baseUrl, Dio? dio, String? apiKey})
    : _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl;
    if (apiKey != null && apiKey.isNotEmpty) {
      _dio.options.headers['X-Api-Key'] = apiKey;
    }
  }

  final Dio _dio;

  Future<MyNodeInfo> getMyNode() async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>('/api/v1/node'),
    );
    final data = response.data!;
    return MyNodeInfo(
      nodeId: data['nodeId'] as String,
      publicKeyBase64: data['publicKeyBase64'] as String,
      relayUrl: data['relayUrl'] as String?,
    );
  }

  Future<List<FederationFriend>> listFriends() async {
    final response = await _handle(
      () => _dio.get<List<dynamic>>('/api/v1/federation/friends'),
    );
    return [
      for (final entry in response.data ?? const [])
        FederationFriend.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<FriendConnectionStatus> getFriendStatus(String nodeId) async {
    final response = await _handle(
      () => _dio.get<Map<String, dynamic>>(
        '/api/v1/federation/friends/$nodeId/status',
      ),
    );
    return FriendConnectionStatus.fromJson(response.data!);
  }

  Future<void> removeFriend(String nodeId) async {
    await _handle(
      () => _dio.delete<void>('/api/v1/federation/friends/$nodeId'),
    );
  }

  /// A fresh, single-use code a friend can redeem (via [addFriend] on
  /// *their* device) to be trusted by this node.
  Future<String> generatePairingCode() async {
    final response = await _handle(
      () => _dio.post<Map<String, dynamic>>('/api/v1/federation/pairing-codes'),
    );
    return response.data!['code'] as String;
  }

  /// Redeems [code] against the friend's own Musicat Server at
  /// [friendBaseUrl], registering *this* node (at [myPublicAddress], the
  /// address the friend's server should use to reach this one back) as
  /// their friend.
  ///
  /// This only grants trust in one direction — the friend now trusts this
  /// node. For the reverse (this node trusting them), they need to
  /// separately redeem a code of this node's own, the same way, on their
  /// own device.
  Future<void> addFriend({
    required String friendBaseUrl,
    required String code,
    required String myPublicAddress,
    String? displayName,
  }) async {
    final myNode = await getMyNode();
    final friendDio = Dio()..options.baseUrl = friendBaseUrl;
    try {
      await friendDio.post<void>(
        '/api/v1/federation/friends',
        data: {
          'code': code,
          'nodeId': myNode.nodeId,
          'publicKeyBase64': myNode.publicKeyBase64,
          'address': myPublicAddress,
          'displayName': ?displayName,
          'relayUrl': ?myNode.relayUrl,
        },
      );
    } on DioException catch (e) {
      throw FederationClientException(
        e.response?.statusCode ?? 0,
        _errorMessage(e),
      );
    }
  }

  /// Sets (or, with `nickname: null`, clears) [nodeId]'s purely local
  /// [FederationFriend.localNickname] on this device's own Musicat Server.
  /// Never sent to, or seen by, the friend it labels. Throws
  /// [FederationClientException] with a 404 status for an unknown
  /// [nodeId].
  Future<FederationFriend> setLocalNickname(
    String nodeId,
    String? nickname,
  ) async {
    final response = await _handle(
      () => _dio.patch<Map<String, dynamic>>(
        '/api/v1/federation/friends/$nodeId',
        data: {'localNickname': nickname},
      ),
    );
    return FederationFriend.fromJson(response.data!);
  }

  Future<Response<T>> _handle<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw FederationClientException(
        e.response?.statusCode ?? 0,
        _errorMessage(e),
      );
    }
  }

  String _errorMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (data is String) return data;
    return e.message ?? 'Unknown error';
  }
}
