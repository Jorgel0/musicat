import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/library_repository_drift.dart';
import '../data/library_scanner.dart';
import '../domain/album_summary.dart';
import '../domain/artist_summary.dart';
import '../domain/library_grouping.dart';
import '../domain/library_repository.dart';
import '../domain/track.dart';

final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  return DriftLibraryRepository(ref.watch(appDatabaseProvider));
});

final libraryScannerProvider = Provider<LibraryScanner>((ref) {
  return LibraryScanner(ref.watch(libraryRepositoryProvider));
});

final tracksProvider = StreamProvider<List<Track>>((ref) {
  return ref.watch(libraryRepositoryProvider).watchAllTracks();
});

final albumsProvider = Provider<List<AlbumSummary>>((ref) {
  final tracks = ref.watch(tracksProvider).value ?? const [];
  return groupTracksByAlbum(tracks);
});

final artistsProvider = Provider<List<ArtistSummary>>((ref) {
  final tracks = ref.watch(tracksProvider).value ?? const [];
  return groupTracksByArtist(tracks);
});
