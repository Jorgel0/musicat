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

  /// Folders added via "Add folder", so Settings can list/re-scan/forget
  /// them without inferring folders back out of track file paths.
  Stream<List<String>> watchFolders();
  Future<void> addFolder(String path);
  Future<void> removeFolder(String path);
}
