import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/player/presentation/mini_player.dart';

/// Wraps every top-level route with the persistent mini-player and the
/// section switcher (library/playlists).
class AppShell extends StatelessWidget {
  const AppShell({required this.child, required this.location, super.key});

  final Widget child;
  final String location;

  int get _currentIndex => location.startsWith('/playlists') ? 1 : 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) {
              context.go(index == 0 ? '/' : '/playlists');
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: 'Playlists',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
