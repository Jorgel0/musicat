import 'package:musicat/core/network/federation/federation_client.dart';

/// Captures a single [FederationClient.addFriend] call's arguments — see
/// [FakeFederationClient.addFriendCalls].
class AddFriendCall {
  const AddFriendCall({
    required this.friendBaseUrl,
    required this.code,
    required this.myPublicAddress,
    required this.displayName,
  });

  final String friendBaseUrl;
  final String code;
  final String myPublicAddress;
  final String? displayName;
}

/// Hand-written in-memory fake standing in for [FederationClient] in tests
/// that need to inspect exactly what a controller sent (e.g.
/// [FriendsController.addFriend]'s `displayName` argument), or drive a
/// realistic add/remove/set-nickname/refresh cycle without hitting the
/// network. [FederationClient.addFriend] posts to a second, non-injectable
/// `Dio` pointed at the friend's own server, which the shared
/// `FakeHttpAdapter` pattern used elsewhere in this test suite can't
/// intercept — this fake exists for exactly that gap, following the same
/// "implements the real interface, log calls, no mocking framework"
/// pattern as `FakeSoulseekClient`.
class FakeFederationClient implements FederationClient {
  FakeFederationClient({
    MyNodeInfo? myNode,
    List<FederationFriend> friends = const [],
  }) : myNode =
           myNode ??
           const MyNodeInfo(nodeId: 'my-node', publicKeyBase64: 'my-pk'),
       friends = List.of(friends);

  MyNodeInfo myNode;
  List<FederationFriend> friends;
  final Map<String, FriendConnectionStatus> statusByNodeId = {};

  final List<AddFriendCall> addFriendCalls = [];
  final List<String> removedNodeIds = [];
  final List<({String nodeId, String? nickname})> setLocalNicknameCalls = [];

  /// Overrides [setUsername]'s outcome: `null` (the default) means every
  /// call succeeds; otherwise thrown as-is on every call — typically a
  /// [FederationClientException], to drive a specific error (e.g. a 409
  /// "already taken") through the same real UI path a live one would.
  Object? setUsernameError;
  final List<String> setUsernameCalls = [];

  /// Username -> nodeId entries this fake's directory knows about — backs
  /// [lookupUsername]'s success case. A username missing from this map
  /// throws the same 404 [FederationClientException] the real relay's own
  /// `/directory/lookup` route would.
  Map<String, String> usernameDirectory = {};

  /// Overrides [lookupUsername]'s outcome entirely (e.g. a 503 "no relay
  /// connected"), regardless of [usernameDirectory] — `null` (the
  /// default) falls back to the directory-lookup behavior above.
  Object? lookupUsernameError;
  final List<String> lookupUsernameCalls = [];

  @override
  Future<MyNodeInfo> getMyNode() async => myNode;

  @override
  Future<List<FederationFriend>> listFriends() async => List.of(friends);

  @override
  Future<FriendConnectionStatus> getFriendStatus(String nodeId) async =>
      statusByNodeId[nodeId] ?? const FriendConnectionStatus(connected: false);

  @override
  Future<void> removeFriend(String nodeId) async {
    removedNodeIds.add(nodeId);
    friends = friends.where((f) => f.nodeId != nodeId).toList();
  }

  @override
  Future<String> generatePairingCode() async => 'fake-pairing-code';

  @override
  Future<void> addFriend({
    required String friendBaseUrl,
    required String code,
    required String myPublicAddress,
    String? displayName,
  }) async {
    addFriendCalls.add(
      AddFriendCall(
        friendBaseUrl: friendBaseUrl,
        code: code,
        myPublicAddress: myPublicAddress,
        displayName: displayName,
      ),
    );
  }

  @override
  Future<void> setUsername(String username) async {
    setUsernameCalls.add(username);
    final error = setUsernameError;
    if (error != null) throw error;
  }

  @override
  Future<String> lookupUsername(String username) async {
    lookupUsernameCalls.add(username);
    final error = lookupUsernameError;
    if (error != null) throw error;
    final nodeId = usernameDirectory[username];
    if (nodeId == null) {
      throw const FederationClientException(404, 'Username not found');
    }
    return nodeId;
  }

  @override
  Future<FederationFriend> setLocalNickname(
    String nodeId,
    String? nickname,
  ) async {
    setLocalNicknameCalls.add((nodeId: nodeId, nickname: nickname));
    final index = friends.indexWhere((f) => f.nodeId == nodeId);
    if (index == -1) {
      throw const FederationClientException(404, 'Unknown friend');
    }
    final existing = friends[index];
    final updated = FederationFriend(
      nodeId: existing.nodeId,
      publicKeyBase64: existing.publicKeyBase64,
      address: existing.address,
      displayName: existing.displayName,
      relayUrl: existing.relayUrl,
      localNickname: nickname,
    );
    friends[index] = updated;
    return updated;
  }
}
