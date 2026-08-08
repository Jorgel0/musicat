enum TrackSource { local, soulseek }

class Track {
  const Track({
    required this.id,
    required this.filePath,
    required this.title,
    required this.artist,
    required this.album,
    required this.source,
    this.trackNumber,
    this.duration,
    this.coverArtPath,
  });

  final int id;
  final String filePath;
  final String title;
  final String artist;
  final String album;
  final TrackSource source;
  final int? trackNumber;
  final Duration? duration;
  final String? coverArtPath;
}
