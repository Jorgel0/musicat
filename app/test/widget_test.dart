import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicat/app.dart';
import 'package:musicat/core/audio/audio_providers.dart';
import 'package:musicat/features/library/presentation/library_providers.dart';

import 'fakes/fake_audio_player_controller.dart';
import 'fakes/fake_library_repository.dart';

void main() {
  testWidgets('renders the library screen with an empty state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(
            FakeEmptyLibraryRepository(),
          ),
          audioPlayerControllerProvider.overrideWithValue(
            FakeAudioPlayerController(),
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
