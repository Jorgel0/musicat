import 'track.dart';

abstract interface class LibraryRepository {
  Stream<List<Track>> watchAllTracks();

  Future<void> upsertTrack({
    required String filePath,
    required String title,
    required String artist,
    required String album,
    required TrackSource source,
    int? trackNumber,
    Duration? duration,
    String? coverArtPath,
  });
}
