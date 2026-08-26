import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/player/presentation/mini_player.dart';
import '../invite/pending_invite.dart';

/// Wraps every top-level route with the persistent mini-player and the
/// section switcher (library/playlists/settings).
///
/// Also the catch-all for a `musicat://` deep link that failed to parse
/// (see `app_router.dart`'s `_handleDeepLink`, which redirects those to
/// `/` — every top-level route passes through here): surfaces it as a
/// SnackBar so a bad/expired invite link is never silently dropped. Two
/// hooks are needed for this, not just one: `initState` handles the link
/// arriving before this shell (persistent across in-shell navigation, per
/// `ShellRoute`) has ever built — e.g. a cold app launch straight from a
/// bad link — while `ref.listen` in `build` handles one arriving later,
/// while the shell is already mounted.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.child, required this.location, super.key});

  final Widget child;
  final String location;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowPendingInviteError(ref.read(pendingInviteProvider)),
    );
  }

  void _maybeShowPendingInviteError(PendingInvite? pending) {
    if (pending is! PendingInviteError) return;
    ref.read(pendingInviteProvider.notifier).consume();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(pending.message)));
  }

  int get _currentIndex {
    final location = widget.location;
    if (location.startsWith('/search')) return 1;
    if (location.startsWith('/downloads')) return 2;
    if (location.startsWith('/playlists')) return 3;
    if (location.startsWith('/friends')) return 4;
    if (location.startsWith('/settings')) return 5;
    return 0;
  }

  static const _destinations = [
    '/',
    '/search',
    '/downloads',
    '/playlists',
    '/friends',
    '/settings',
  ];

  @override
  Widget build(BuildContext context) {
    ref.listen<PendingInvite?>(
      pendingInviteProvider,
      (previous, next) => _maybeShowPendingInviteError(next),
    );

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) => context.go(_destinations[index]),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search),
                label: 'Search',
              ),
              NavigationDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download),
                label: 'Downloads',
              ),
              NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: 'Playlists',
              ),
              NavigationDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: 'Friends',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
