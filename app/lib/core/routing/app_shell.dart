import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/friends/presentation/account_controller.dart';
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
    // `/account` is a Friends-section screen that lives at the top level
    // (see `app_router.dart` for why), so it keeps the Friends tab lit
    // rather than falling through to Library.
    if (location.startsWith('/friends') || location.startsWith('/account')) {
      return 4;
    }
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

    // Unanswered friend requests, surfaced on the nav bar itself: the one
    // place they are visible without already being on the Friends screen.
    // A request nobody notices is the same as not having the feature at
    // all — see `account_controller.dart` for why this provider outlives
    // the Friends screen. `0` while loading, signed out, or unable to
    // check, so the badge only ever appears when there is really
    // something waiting.
    final pendingRequests = ref.watch(pendingFriendRequestCountProvider);

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) => context.go(_destinations[index]),
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Library',
              ),
              const NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search),
                label: 'Search',
              ),
              const NavigationDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download),
                label: 'Downloads',
              ),
              const NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: 'Playlists',
              ),
              NavigationDestination(
                icon: Badge.count(
                  count: pendingRequests,
                  isLabelVisible: pendingRequests > 0,
                  child: const Icon(Icons.people_outline),
                ),
                selectedIcon: Badge.count(
                  count: pendingRequests,
                  isLabelVisible: pendingRequests > 0,
                  child: const Icon(Icons.people),
                ),
                label: 'Friends',
              ),
              const NavigationDestination(
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
