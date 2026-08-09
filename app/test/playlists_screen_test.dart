import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/features/playlists/presentation/playlist_providers.dart';
import 'package:musicat/features/playlists/presentation/playlists_screen.dart';

import 'fakes/fake_playlist_repository.dart';

void main() {
  testWidgets(
    'shows the empty state, then the new playlist after creating one',
    (tester) async {
      final repository = FakePlaylistRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [playlistRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(home: PlaylistsScreen()),
        ),
      );
      await tester.pump();

      expect(
        find.text('No playlists yet — create one to get started.'),
        findsOneWidget,
      );

      await tester.tap(find.text('New playlist'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Road trip');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('Road trip'), findsOneWidget);
      expect(
        find.text('No playlists yet — create one to get started.'),
        findsNothing,
      );
    },
  );
}
