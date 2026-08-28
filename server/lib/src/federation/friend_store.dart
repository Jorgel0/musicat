import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'friend.dart';

/// Persists the list of trusted [Friend] nodes to
/// `<dataDirectory>/friends.json`.
class FriendStore {
  FriendStore(this.dataDirectory);

  final Directory dataDirectory;

  File get _file => File(p.join(dataDirectory.path, 'friends.json'));

  Future<List<Friend>> loadAll() async {
    final file = _file;
    if (!file.existsSync()) return [];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return [
      for (final entry in json) Friend.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<Friend?> findByNodeId(String nodeId) async {
    final friends = await loadAll();
    for (final friend in friends) {
      if (friend.nodeId == nodeId) return friend;
    }
    return null;
  }

  /// Adds [friend], replacing any existing entry with the same [Friend.nodeId].
  Future<void> add(Friend friend) async {
    final friends = await loadAll();
    friends.removeWhere((f) => f.nodeId == friend.nodeId);
    friends.add(friend);
    await _save(friends);
  }

  /// Revokes trust in the node with the given [nodeId] — no-op if it wasn't
  /// a friend. Signed requests claiming that `nodeId` are rejected from the
  /// next lookup onward (see `RequestVerifier`).
  Future<void> remove(String nodeId) async {
    final friends = await loadAll();
    friends.removeWhere((f) => f.nodeId == nodeId);
    await _save(friends);
  }

  /// Updates just [Friend.localNickname] for the friend with the given
  /// [nodeId], leaving every other field untouched. Purely local: this
  /// never touches anything sent to or received from the friend itself.
  ///
  /// Returns the updated [Friend], or `null` if [nodeId] isn't a known
  /// friend (in which case nothing is saved).
  Future<Friend?> setLocalNickname(String nodeId, String? nickname) async {
    final friends = await loadAll();
    final index = friends.indexWhere((f) => f.nodeId == nodeId);
    if (index == -1) return null;

    final existing = friends[index];
    final updated = Friend(
      nodeId: existing.nodeId,
      publicKeyBase64: existing.publicKeyBase64,
      address: existing.address,
      displayName: existing.displayName,
      udpCandidate: existing.udpCandidate,
      relayUrl: existing.relayUrl,
      localNickname: nickname,
    );
    friends[index] = updated;
    await _save(friends);
    return updated;
  }

  Future<void> _save(List<Friend> friends) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final friend in friends) friend.toJson()]),
    );
  }
}
