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
