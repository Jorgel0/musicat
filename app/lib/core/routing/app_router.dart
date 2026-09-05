import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/downloads/presentation/downloads_screen.dart';
import '../../features/friends/presentation/account_screen.dart';
import '../../features/friends/presentation/friend_detail_screen.dart';
import '../../features/friends/presentation/friends_screen.dart';
import '../../features/friends/presentation/my_profile_screen.dart';
import '../../features/library/presentation/album_detail_screen.dart';
import '../../features/library/presentation/artist_detail_screen.dart';
import '../../features/library/presentation/library_screen.dart';
import '../../features/player/presentation/now_playing_screen.dart';
import '../../features/playlists/presentation/joint_playlist_detail_screen.dart';
import '../../features/playlists/presentation/playlist_detail_screen.dart';
import '../../features/playlists/presentation/playlists_screen.dart';
import '../../features/search/presentation/search_screen.dart';
import '../../features/settings/audio/presentation/equalizer_screen.dart';
import '../../features/settings/general/presentation/settings_screen.dart';
import '../../features/settings/soulseek/presentation/soulseek_settings_screen.dart';
import '../invite/invite_uri.dart';
import '../invite/pending_invite.dart';
import 'app_shell.dart';

/// Builds a fresh, independently-configured [GoRouter] wired exactly like
/// the app's own [appRouter] (same routes, same [_handleDeepLink]
/// `redirect`). [appRouter] itself is just `createAppRouter()` called once;
/// tests that need a genuine cold start call this directly instead, since a
/// real [GoRouter] only reads
/// `WidgetsBinding.instance.platformDispatcher.defaultRouteName` once, at
/// construction — reusing the single app-lifetime [appRouter] instance
/// across more than one "cold start" deep link within the same test process
/// wouldn't actually re-run that initial-location logic a second time.
GoRouter createAppRouter() => GoRouter(
  redirect: _handleDeepLink,
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(path: '/', builder: (context, state) => const LibraryScreen()),
        GoRoute(
          path: '/search',
          builder: (context, state) => const SearchScreen(),
        ),
        GoRoute(
          path: '/downloads',
          builder: (context, state) => const DownloadsScreen(),
        ),
        GoRoute(
          path: '/albums/detail',
          builder: (context, state) {
            final args =
                state.extra! as ({String albumName, String artistName});
            return AlbumDetailScreen(
              albumName: args.albumName,
              artistName: args.artistName,
            );
          },
        ),
        GoRoute(
          path: '/artists/detail',
          builder: (context, state) =>
              ArtistDetailScreen(artistName: state.extra! as String),
        ),
        GoRoute(
          path: '/playlists',
          builder: (context, state) => const PlaylistsScreen(),
          routes: [
            GoRoute(
              path: ':id',
              builder: (context, state) => PlaylistDetailScreen(
                playlistId: int.parse(state.pathParameters['id']!),
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/joint-playlists/:id',
          builder: (context, state) => JointPlaylistDetailScreen(
            playlistId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/my-profile',
          builder: (context, state) => const MyProfileScreen(),
        ),
        // Top-level rather than under `/friends`, which already owns a
        // `:nodeId` child route that would happily match `account` as a
        // node id.
        GoRoute(
          path: '/account',
          builder: (context, state) => const AccountScreen(),
        ),
        GoRoute(
          path: '/friends',
          builder: (context, state) => const FriendsScreen(),
          routes: [
            GoRoute(
              path: ':nodeId',
              builder: (context, state) =>
                  FriendDetailScreen(nodeId: state.pathParameters['nodeId']!),
            ),
          ],
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
          routes: [
            GoRoute(
              path: 'equalizer',
              builder: (context, state) => const EqualizerScreen(),
            ),
            GoRoute(
              path: 'soulseek',
              builder: (context, state) => const SoulseekSettingsScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/now-playing',
      builder: (context, state) => const NowPlayingScreen(),
    ),
  ],
);

final appRouter = createAppRouter();

/// Top-level redirect: intercepts an incoming `musicat://friend|playlist`
/// invite link (Android deep link — see the second `<intent-filter>` on
/// `MainActivity` in `AndroidManifest.xml`) before go_router tries to match
/// it against a normal `/...` route. A `musicat://` URI's scheme/host shape
/// doesn't correspond to any registered path here, so it would otherwise
/// just 404 into the error page.
///
/// Stashes the parsed invite in [pendingInviteProvider] for the landing
/// screen (`FriendsScreen`, `PlaylistsScreen`) to notice on its first frame
/// and open a pre-filled sheet, then redirects to that screen's normal
/// route. A link that fails to parse still isn't silently dropped: it's
/// recorded as a [PendingInviteError] and lands on `/`, where `AppShell`
/// shows it as a SnackBar.
///
/// The actual provider write in both branches below is deferred with
/// `Future.microtask` — same technique, same reason, as `FriendsController.
/// build()`'s fix in ADR 0037. `redirect` can run synchronously from
/// `_RouterState.didChangeDependencies()`, a widget lifecycle method, most
/// notably on a cold app start (launched fresh straight from tapping a
/// `musicat://...` link) — still inside Flutter's initial build pass.
/// Writing to a Riverpod provider synchronously from there trips Riverpod's
/// "Tried to modify a provider while the widget tree was building" debug
/// guard, which go_router swallows into its generic error route, silently
/// losing the invite. The redirect *target* below doesn't need the write to
/// have happened yet — only `InviteUri.parseUri`'s result, computed
/// synchronously either way — so it's still returned synchronously; only
/// the write to [pendingInviteProvider] is pushed past the current frame.
/// The landing screen's own `addPostFrameCallback` (`FriendsScreen`,
/// `PlaylistsScreen`, `AppShell`) is what actually reads the provider, and
/// runs after any microtask scheduled during the current frame has
/// flushed, so it always sees the write.
String? _handleDeepLink(BuildContext context, GoRouterState state) {
  final uri = state.uri;
  if (uri.scheme != InviteUri.scheme) return null;

  final container = ProviderScope.containerOf(context, listen: false);
  try {
    final payload = InviteUri.parseUri(uri);
    final pending = switch (payload) {
      FriendInvite() => PendingFriendInvite(payload),
      PlaylistInvite() => PendingPlaylistInvite(payload),
    };
    Future.microtask(
      () => container.read(pendingInviteProvider.notifier).set(pending),
    );
    return switch (payload) {
      FriendInvite() => '/friends',
      PlaylistInvite() => '/playlists',
    };
  } on InviteUriException catch (e) {
    Future.microtask(
      () => container
          .read(pendingInviteProvider.notifier)
          .set(PendingInviteError(e.message)),
    );
    return '/';
  }
}
