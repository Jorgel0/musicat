import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/invite/invite_uri.dart';
import 'package:musicat/features/friends/presentation/musicat_server_config_controller.dart';
import 'package:musicat/features/playlists/presentation/joint_playlist_detail_screen.dart';
import 'package:musicat/features/playlists/presentation/joint_playlist_providers.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'fakes/fake_http_adapter.dart';

JointPlaylistClient _clientReturning(Map<String, dynamic> playlistJson) {
  final adapter = FakeHttpAdapter((options) {
    if (options.path.startsWith('/api/v1/playlists/')) {
      return FakeHttpResponse(200, playlistJson);
    }
    throw StateError('Unexpected request: ${options.path}');
  });
  final dio = Dio()..httpClientAdapter = adapter;
  return JointPlaylistClient(baseUrl: 'http://musicat-server.test', dio: dio);
}

void main() {
  testWidgets("the share-id dialog's QR code encodes the playlist invite link "
      '(id + name), alongside the existing copy button', (tester) async {
    final client = _clientReturning({
      'id': 'playlist-abc',
      'name': 'Road trip',
      'participantNodeIds': <String>[],
      'items': <dynamic>[],
      'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
    });

    final container = ProviderContainer(
      overrides: [jointPlaylistClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: JointPlaylistDetailScreen(playlistId: 'playlist-abc'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip("Share this playlist's id with a friend"));
    await tester.pumpAndSettle();

    // The existing copy-id affordance is still there, untouched.
    expect(find.text('playlist-abc'), findsOneWidget);
    expect(find.byTooltip('Copy'), findsOneWidget);

    // New: a share button, and a QR code encoding the same invite link.
    expect(find.byTooltip('Share invite link'), findsOneWidget);
    final expectedUri = InviteUri.build(
      const PlaylistInvite(id: 'playlist-abc', name: 'Road trip'),
    ).toString();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(
      find.byKey(ValueKey('playlist-invite-qr:$expectedUri')),
      findsOneWidget,
    );
  });
}
