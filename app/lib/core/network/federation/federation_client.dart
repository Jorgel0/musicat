import 'package:dio/dio.dart';

/// This device's own node identity, as reported by its Musicat Server.
class MyNodeInfo {
  const MyNodeInfo({required this.nodeId, required this.publicKeyBase64});

  final String nodeId;
  final String publicKeyBase64;
}

/// A trusted friend node, as this device's Musicat Server knows it.
class FederationFriend {
  const FederationFriend({
    required this.nodeId,
    required this.publicKeyBase64,
    required this.address,
    this.displayName,
  });

  final String nodeId;
  final String publicKeyBase64;
  final String address;
  final String? displayName;

  factory FederationFriend.fromJson(Map<String, dynamic> json) =>
      FederationFriend(
        nodeId: json['nodeId'] as String,
        publicKeyBase64: json['publicKeyBase64'] as String,
        address: json['address'] as String,
        displayName: json['displayName'] as String?,
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
  FederationClient({required String baseUrl, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl;
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
        },
      );
    } on DioException catch (e) {
      throw FederationClientException(
        e.response?.statusCode ?? 0,
        _errorMessage(e),
      );
    }
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
