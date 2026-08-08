import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/design_system/theme.dart';
import 'core/routing/app_router.dart';

class MusicatApp extends ConsumerWidget {
  const MusicatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Musicat',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: MusicatTheme.light,
      darkTheme: MusicatTheme.dark,
      routerConfig: appRouter,
    );
  }
}

/// Placeholder home screen for Phase 0, proving the app compiles and runs
/// end to end on every target. Phase 1 replaces this with the real
/// library/player shell.
class HelloMusicatScreen extends StatelessWidget {
  const HelloMusicatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_note_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('Musicat', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'Phase 0 — scaffold running.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
