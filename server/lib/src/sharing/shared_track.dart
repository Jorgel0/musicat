/// Who a [SharedTrack] is visible to and downloadable by.
///
/// This is the object-level authorization check every sharing route must
/// go through in addition to [RequestVerifier]'s "is this even a known
/// friend" check (see `sharing_routes.dart`) — being *a* friend is
/// necessary but never sufficient; a track must specifically have been
/// shared with *this* friend (or set of friends), or with all of them.
///
/// **What "this friend" means is a friend *account* (`Friend.accountId`),
/// never one of that account's devices.** A friend who shares a track from
/// their phone and downloads it on their desktop is one friend, and every
/// device currently linked to their account is equally them. The persisted
/// ids therefore have to be account ids — [FriendsVisibility] compares
/// nothing else — which is exactly why every id entering a visibility rule
/// is normalized through `FriendStore` at write time (see
/// `sharing_routes.dart`'s `POST /shared-tracks`).
///
/// For a legacy device-pinned friend an account id *is* their nodeId, so
/// every rule persisted before accounts existed keeps meaning exactly what
/// it meant. A raw device nodeId of a genuine multi-device account left in
/// a rule matches nobody at all — deliberately fail-closed: matching it
/// would mean a device that has since moved to a *different* account could
/// unlock a track shared with the account it used to belong to.
abstract class SharedTrackVisibility {
  const SharedTrackVisibility();

  /// Shared with exactly this one friend account (e.g. a direct "send to a
  /// friend") — equivalent to `FriendsVisibility({accountId})`.
  factory SharedTrackVisibility.friend(String accountId) =>
      FriendsVisibility({accountId});

  const factory SharedTrackVisibility.allFriends() = AllFriendsVisibility;

  /// Whether [requestingAccountId] — already confirmed to be a known,
  /// signed-in friend account by the caller (see [verifiedFriendAccountId])
  /// — may see/download this track.
  bool allows(String requestingAccountId);

  Map<String, Object?> toJson();

  factory SharedTrackVisibility.fromJson(Map<String, dynamic> json) {
    return switch (json['type']) {
      // 'friend' (a single id) is still accepted for backward
      // compatibility with anything already persisted before
      // FriendsVisibility replaced it.
      'friend' => FriendsVisibility({json['nodeId'] as String}),
      'friends' => FriendsVisibility({
        for (final id in json['nodeIds'] as List<dynamic>) id as String,
      }),
      'allFriends' => const AllFriendsVisibility(),
      _ => throw FormatException('Unknown visibility type: ${json['type']}'),
    };
  }
}

/// Shared with exactly this set of friend accounts — a direct send is just
/// the one-element case of this, and a joint playlist with N participants
/// (ADR 0027) is the general case: never widened to "all friends" just
/// because there's more than one other participant.
///
/// The JSON keys stay `nodeIds`/`nodeId` (rather than being renamed to
/// match [accountIds]) so no `shared_tracks.json` written before accounts
/// existed needs rewriting, and so a file this version writes stays
/// readable by the previous one.
class FriendsVisibility extends SharedTrackVisibility {
  const FriendsVisibility(this.accountIds);

  final Set<String> accountIds;

  @override
  bool allows(String requestingAccountId) =>
      accountIds.contains(requestingAccountId);

  @override
  Map<String, Object?> toJson() => {
    'type': 'friends',
    'nodeIds': accountIds.toList(),
  };
}

/// Shared with every current friend (e.g. a curated "profile" of tracks).
class AllFriendsVisibility extends SharedTrackVisibility {
  const AllFriendsVisibility();

  @override
  bool allows(String requestingAccountId) => true;

  @override
  Map<String, Object?> toJson() => {'type': 'allFriends'};
}

/// e.g. `.flac` for `/music/one-more-time.flac` — shared with `PlaylistItem`
/// (`playlist_routes.dart`), which needs the same value when it creates the
/// `SharedTrack` backing a newly-added playlist item.
String extensionOf(String filePath) {
  final dot = filePath.lastIndexOf('.');
  return dot == -1 ? '' : filePath.substring(dot);
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
  /// [extension] (e.g. `.flac`) is included despite coming from [filePath]
  /// — it's needed for the friend to name/import the file it downloads,
  /// and reveals nothing about the sharer's actual directory layout.
  Map<String, Object?> toPublicJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'hasCoverArt': coverArtPath != null,
    'extension': extensionOf(filePath),
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
