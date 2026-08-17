/// Who a [SharedTrack] is visible to and downloadable by.
///
/// This is the object-level authorization check every sharing route must
/// go through in addition to [RequestVerifier]'s "is this even a known
/// friend" check (see `sharing_routes.dart`) — being *a* friend is
/// necessary but never sufficient; a track must specifically have been
/// shared with *this* friend, or with all of them.
abstract class SharedTrackVisibility {
  const SharedTrackVisibility();

  factory SharedTrackVisibility.friend(String nodeId) = FriendVisibility;

  const factory SharedTrackVisibility.allFriends() = AllFriendsVisibility;

  /// Whether [requestingNodeId] — already confirmed to be a known,
  /// signed-in friend by the caller — may see/download this track.
  bool allows(String requestingNodeId);

  Map<String, Object?> toJson();

  factory SharedTrackVisibility.fromJson(Map<String, dynamic> json) {
    return switch (json['type']) {
      'friend' => FriendVisibility(json['nodeId'] as String),
      'allFriends' => const AllFriendsVisibility(),
      _ => throw FormatException('Unknown visibility type: ${json['type']}'),
    };
  }
}

/// Shared with one specific friend only (e.g. a direct "send to a friend").
class FriendVisibility extends SharedTrackVisibility {
  const FriendVisibility(this.nodeId);

  final String nodeId;

  @override
  bool allows(String requestingNodeId) => requestingNodeId == nodeId;

  @override
  Map<String, Object?> toJson() => {'type': 'friend', 'nodeId': nodeId};
}

/// Shared with every current friend (e.g. a curated "profile" of tracks).
class AllFriendsVisibility extends SharedTrackVisibility {
  const AllFriendsVisibility();

  @override
  bool allows(String requestingNodeId) => true;

  @override
  Map<String, Object?> toJson() => {'type': 'allFriends'};
}

/// A local file this node has offered to share — never the file itself,
/// just its metadata, until a friend specifically asks to download it
/// (see `sharing_routes.dart`).
class SharedTrack {
  const SharedTrack({
    required this.id,
    required this.filePath,
    required this.title,
    required this.artist,
    required this.visibility,
    this.album,
    this.coverArtPath,
  });

  final String id;

  /// Local path on *this* server's own disk — never sent to a friend
  /// directly; only used server-side to serve the file/cover bytes.
  final String filePath;

  final String title;
  final String artist;
  final String? album;
  final String? coverArtPath;
  final SharedTrackVisibility visibility;

  /// What's safe to expose to a friend browsing what's shared with them —
  /// deliberately omits [filePath]/[coverArtPath] (local disk paths,
  /// meaningless — and a path-disclosure risk — to a remote peer) and
  /// [visibility] (irrelevant to the friend it's already been resolved for).
  Map<String, Object?> toPublicJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'hasCoverArt': coverArtPath != null,
  };

  Map<String, Object?> toStorageJson() => {
    'id': id,
    'filePath': filePath,
    'title': title,
    'artist': artist,
    'album': album,
    'coverArtPath': coverArtPath,
    'visibility': visibility.toJson(),
  };

  factory SharedTrack.fromStorageJson(Map<String, dynamic> json) => SharedTrack(
    id: json['id'] as String,
    filePath: json['filePath'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String?,
    coverArtPath: json['coverArtPath'] as String?,
    visibility: SharedTrackVisibility.fromJson(
      json['visibility'] as Map<String, dynamic>,
    ),
  );
}
