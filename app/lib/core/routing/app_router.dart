import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/downloads/presentation/downloads_screen.dart';
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

final appRouter = GoRouter(
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
String? _handleDeepLink(BuildContext context, GoRouterState state) {
  final uri = state.uri;
  if (uri.scheme != InviteUri.scheme) return null;

  final container = ProviderScope.containerOf(context, listen: false);
  try {
    final payload = InviteUri.parseUri(uri);
    container.read(pendingInviteProvider.notifier).set(switch (payload) {
      FriendInvite() => PendingFriendInvite(payload),
      PlaylistInvite() => PendingPlaylistInvite(payload),
    });
    return switch (payload) {
      FriendInvite() => '/friends',
      PlaylistInvite() => '/playlists',
    };
  } on InviteUriException catch (e) {
    container
        .read(pendingInviteProvider.notifier)
        .set(PendingInviteError(e.message));
    return '/';
  }
}
