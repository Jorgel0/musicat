import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:musicat/core/invite/invite_uri.dart';
import 'package:musicat/core/invite/pending_invite.dart';
import 'package:musicat/core/network/social/joint_playlist_client.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';
import 'package:musicat/features/playlists/presentation/joint_playlist_detail_screen.dart';
import 'package:musicat/features/playlists/presentation/playlist_providers.dart';
import 'package:musicat/features/playlists/presentation/playlists_screen.dart';

import 'fakes/fake_http_adapter.dart';
import 'fakes/fake_playlist_repository.dart';

JointPlaylistClient _jointClientWith(
  FakeHttpResponse Function(RequestOptions options) handler,
) {
  final adapter = FakeHttpAdapter(handler);
  final dio = Dio()..httpClientAdapter = adapter;
  return JointPlaylistClient(baseUrl: 'http://musicat-server.test', dio: dio);
}

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

  group('PlaylistsScreen pending playlist invite (deep link)', () {
    testWidgets(
      'not-yet-joined: opens the create/join sheet pre-filled with the '
      "invite's id and name",
      (tester) async {
        final client = _jointClientWith((options) {
          if (options.method == 'GET' && options.path == '/api/v1/playlists') {
            return const FakeHttpResponse(200, <dynamic>[]);
          }
          throw StateError(
            'Unexpected request: ${options.method} ${options.path}',
          );
        });

        final container = ProviderContainer(
          overrides: [
            playlistRepositoryProvider.overrideWithValue(
              FakePlaylistRepository(),
            ),
            jointPlaylistClientProvider.overrideWithValue(client),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(pendingInviteProvider.notifier)
            .set(
              const PendingPlaylistInvite(
                PlaylistInvite(id: 'invited-id', name: 'Party Mix'),
              ),
            );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: PlaylistsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('New joint playlist'), findsOneWidget);
        final idField = tester.widget<TextField>(
          find.widgetWithText(
            TextField,
            'Joining an existing one? Paste its id',
          ),
        );
        expect(idField.controller!.text, 'invited-id');
        final nameField = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Name'),
        );
        expect(nameField.controller!.text, 'Party Mix');

        // Consumed — a rebuild doesn't reopen it a second time.
        expect(container.read(pendingInviteProvider), isNull);
      },
    );

    testWidgets(
      'already-joined: navigates straight to the joint playlist, no sheet',
      (tester) async {
        final playlistJson = {
          'id': 'already-joined-id',
          'name': 'Existing playlist',
          'participantNodeIds': <String>[],
          'items': <dynamic>[],
          'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
        };
        final client = _jointClientWith((options) {
          if (options.method == 'GET' && options.path == '/api/v1/playlists') {
            return FakeHttpResponse(200, [playlistJson]);
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/playlists/already-joined-id') {
            return FakeHttpResponse(200, playlistJson);
          }
          throw StateError(
            'Unexpected request: ${options.method} ${options.path}',
          );
        });

        final container = ProviderContainer(
          overrides: [
            playlistRepositoryProvider.overrideWithValue(
              FakePlaylistRepository(),
            ),
            jointPlaylistClientProvider.overrideWithValue(client),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(pendingInviteProvider.notifier)
            .set(
              const PendingPlaylistInvite(
                PlaylistInvite(
                  id: 'already-joined-id',
                  name: 'Existing playlist',
                ),
              ),
            );

        final router = GoRouter(
          initialLocation: '/playlists',
          routes: [
            GoRoute(
              path: '/playlists',
              builder: (context, state) => const PlaylistsScreen(),
            ),
            GoRoute(
              path: '/joint-playlists/:id',
              builder: (context, state) => JointPlaylistDetailScreen(
                playlistId: state.pathParameters['id']!,
              ),
            ),
          ],
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(JointPlaylistDetailScreen), findsOneWidget);
        expect(find.text('New joint playlist'), findsNothing);
        expect(container.read(pendingInviteProvider), isNull);
      },
    );
  });
}
