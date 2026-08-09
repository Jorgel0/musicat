import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/design_system/theme.dart';
import 'package:musicat/features/library/presentation/library_providers.dart';
import 'package:musicat/features/settings/general/presentation/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_library_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the empty folders state and switches theme mode', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(
          FakeEmptyLibraryRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('No folders added yet.'), findsOneWidget);
    expect(container.read(themeModeProvider), ThemeMode.system);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(container.read(themeModeProvider), ThemeMode.dark);
  });

  testWidgets('switches the accent color', (tester) async {
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(
          FakeEmptyLibraryRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();

    final secondAccent = MusicatTheme.accentOptions[1];
    expect(container.read(accentColorProvider), isNot(secondAccent));

    await tester.tap(
      find.byWidgetPredicate((widget) {
        return widget is CircleAvatar && widget.backgroundColor == secondAccent;
      }),
    );
    await tester.pumpAndSettle();

    expect(container.read(accentColorProvider), secondAccent);
  });
}
