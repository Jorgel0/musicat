import 'package:go_router/go_router.dart';

import '../../features/library/presentation/album_detail_screen.dart';
import '../../features/library/presentation/artist_detail_screen.dart';
import '../../features/library/presentation/library_screen.dart';
import '../../features/player/presentation/now_playing_screen.dart';
import '../../features/playlists/presentation/playlist_detail_screen.dart';
import '../../features/playlists/presentation/playlists_screen.dart';
import 'app_shell.dart';

final appRouter = GoRouter(
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(path: '/', builder: (context, state) => const LibraryScreen()),
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
      ],
    ),
    GoRoute(
      path: '/now-playing',
      builder: (context, state) => const NowPlayingScreen(),
    ),
  ],
);
