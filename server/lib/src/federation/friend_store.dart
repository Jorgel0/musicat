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

  Future<void> _save(List<Friend> friends) async {
    await dataDirectory.create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final friend in friends) friend.toJson()]),
    );
  }
}
