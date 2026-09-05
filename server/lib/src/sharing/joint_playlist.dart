import 'playlist_item.dart';

/// A playlist shared between this node and one or more friends — each
/// participant can add their own tracks (see `playlist_routes.dart`), and
/// [items] added by anyone are offered to every other participant for
/// download, backed by [PlaylistItem.sharedTrackId] on the adder's own
/// server.
///
/// Each participant keeps their *own* copy of a joint playlist (there's no
/// central server holding one true version) and reconciles it with the
/// others' copies via [JointPlaylistStore.mergeRemote] — see ADR 0026 for
/// why that's a per-item union rather than whole-object
/// last-write-wins, and what that trades away.
class JointPlaylist {
  const JointPlaylist({
    required this.id,
    required this.name,
    required this.participantAccountIds,
    required this.items,
    required this.updatedAt,
  });

  final String id;
  final String name;

  /// The *other* participants, as friend **account** ids
  /// (`Friend.accountId`) — never includes this node's own id.
  ///
  /// Membership is per account, not per device: a participant who joined
  /// from their phone is still a participant when they call from their
  /// desktop, which is why `playlist_routes.dart` normalizes whatever ids
  /// it is handed through `FriendStore` at creation time, and why the
  /// federation-facing membership check compares a verified *account* id.
  /// For a legacy device-pinned friend an account id is their nodeId, so
  /// every `joint_playlists.json` written before accounts existed keeps
  /// working untouched — which is also why the JSON key below stays
  /// `participantNodeIds`.
  final List<String> participantAccountIds;
  final List<PlaylistItem> items;
  final DateTime updatedAt;

  JointPlaylist copyWith({List<PlaylistItem>? items, DateTime? updatedAt}) =>
      JointPlaylist(
        id: id,
        name: name,
        participantAccountIds: participantAccountIds,
        items: items ?? this.items,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'participantNodeIds': participantAccountIds,
    'items': [for (final item in items) item.toJson()],
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory JointPlaylist.fromJson(Map<String, dynamic> json) => JointPlaylist(
    id: json['id'] as String,
    name: json['name'] as String,
    participantAccountIds: [
      for (final id in json['participantNodeIds'] as List<dynamic>)
        id as String,
    ],
    items: [
      for (final item in json['items'] as List<dynamic>)
        PlaylistItem.fromJson(item as Map<String, dynamic>),
    ],
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}
