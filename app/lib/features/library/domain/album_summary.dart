class AlbumSummary {
  const AlbumSummary({
    required this.name,
    required this.artist,
    required this.coverArtPath,
    required this.trackCount,
  });

  final String name;
  final String artist;
  final String? coverArtPath;
  final int trackCount;
}
