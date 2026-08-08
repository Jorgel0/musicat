import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicat/app.dart';
import 'package:musicat/features/library/domain/library_repository.dart';
import 'package:musicat/features/library/domain/track.dart';
import 'package:musicat/features/library/presentation/library_providers.dart';

class _FakeEmptyLibraryRepository implements LibraryRepository {
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
}

void main() {
  testWidgets('renders the library screen with an empty state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(
            _FakeEmptyLibraryRepository(),
          ),
        ],
        child: const MusicatApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Musicat'), findsOneWidget);
    expect(
      find.text('No tracks yet — add a music folder to get started.'),
      findsOneWidget,
    );
  });
}
