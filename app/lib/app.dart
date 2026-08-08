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
