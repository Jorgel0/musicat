import 'package:musicat/features/library/domain/library_repository.dart';
import 'package:musicat/features/library/domain/track.dart';

/// Always-empty [LibraryRepository] for widget tests that don't exercise
/// library data directly (e.g. [SettingsScreen], the app-level smoke test).
class FakeEmptyLibraryRepository implements LibraryRepository {
  @override
  Stream<List<Track>> watchAllTracks() => Stream.value(const []);

  @override
  Future<void> upsertTrack({
    required String filePath,
    required String title,
    required String artist,
    required String album,
    required TrackSource source,
    int? trackNumber,
    Duration? duration,
    String? coverArtPath,
  }) async {}

  @override
  Stream<List<String>> watchFolders() => Stream.value(const []);

  @override
  Future<void> addFolder(String path) async {}

  @override
  Future<void> removeFolder(String path) async {}
}
