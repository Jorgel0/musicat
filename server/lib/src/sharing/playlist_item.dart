/// One track in a [JointPlaylist] — always backed by a [SharedTrack] on
/// [ownerNodeId]'s own server (created automatically when the item is
/// added), so downloading it reuses the exact same mechanism as any other
/// shared track (ADR 0025), just discovered via the playlist instead of a
/// direct share.
class PlaylistItem {
  const PlaylistItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.ownerNodeId,
    required this.sharedTrackId,
    required this.extension,
    required this.addedAt,
    this.album,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;

  /// Whose server actually holds the file — download it via that node's
  /// `/api/v1/sharing/shared-tracks/<sharedTrackId>/file`.
  final String ownerNodeId;
  final String sharedTrackId;

  /// e.g. `.flac` — duplicated from the backing `SharedTrack` at creation
  /// time (same convenience-denormalization already done for
  /// title/artist/album) so a participant can name the file it downloads
  /// without a separate lookup.
  final String extension;
  final DateTime addedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'ownerNodeId': ownerNodeId,
    'sharedTrackId': sharedTrackId,
    'extension': extension,
    'addedAt': addedAt.toIso8601String(),
  };

  factory PlaylistItem.fromJson(Map<String, dynamic> json) => PlaylistItem(
    id: json['id'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String?,
    ownerNodeId: json['ownerNodeId'] as String,
    sharedTrackId: json['sharedTrackId'] as String,
    extension: json['extension'] as String? ?? '',
    addedAt: DateTime.parse(json['addedAt'] as String),
  );
}
