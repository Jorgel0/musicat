import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/audio/audio_providers.dart';
import 'package:musicat/core/invite/invite_uri.dart';
import 'package:musicat/core/routing/app_router.dart';
import 'package:musicat/features/library/presentation/library_providers.dart';
import 'package:musicat/features/playlists/presentation/playlist_providers.dart';

import 'fakes/fake_audio_player_controller.dart';
import 'fakes/fake_library_repository.dart';
import 'fakes/fake_playlist_repository.dart';

/// Exercises the *real* `appRouter` end to end for a cold app start — i.e.
/// launched fresh straight from tapping a `musicat://...` link, never
/// going through `pendingInviteProvider` directly the way every other
/// deep-link test in this repo does (those all bypass `_handleDeepLink`
/// entirely). This is the exact scenario bug-hunter's report was about:
/// `_handleDeepLink` (go_router's top-level `redirect`) used to write to
/// `pendingInviteProvider` synchronously, from inside
/// `_RouterState.didChangeDependencies()` — still inside Flutter's initial
/// build pass on a cold start — which trips Riverpod's "modified a
/// provider while the widget tree was building" debug guard, gets
/// swallowed by go_router into its generic error route, and silently
/// drops the invite.
///
/// [createAppRouter] (not the shared [appRouter] singleton) is used here
/// deliberately: a real `GoRouter` only reads
/// `WidgetsBinding.instance.platformDispatcher.defaultRouteName` once, at
/// construction, to decide its initial location — reusing one
/// app-lifetime router instance across more than one "cold start" deep
/// link within this same test file wouldn't actually re-run that
/// initial-location logic for the second and third test.
void main() {
  Future<void> pumpColdStart(WidgetTester tester, String deepLink) async {
    // Must be set before the router (and thus before the first
    // pumpWidget/didChangeDependencies) is ever built, to genuinely
    // reproduce a cold start rather than a same-session `context.go(...)`.
    tester.platformDispatcher.defaultRouteNameTestValue = deepLink;
    final router = createAppRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(
            FakeEmptyLibraryRepository(),
          ),
          audioPlayerControllerProvider.overrideWithValue(
            FakeAudioPlayerController(),
          ),
          playlistRepositoryProvider.overrideWithValue(
            FakePlaylistRepository(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'cold start on a musicat://friend link lands on /friends with the Add '
    'Friend sheet open and pre-filled, not the error page',
    (tester) async {
      const invite = FriendInvite(
        address: 'deep-link.example:8080',
        code: 'deep-code',
      );
      final deepLink = InviteUri.build(invite).toString();

      await pumpColdStart(tester, deepLink);

      expect(find.text('Page Not Found'), findsNothing);
      expect(find.widgetWithText(AppBar, 'Friends'), findsOneWidget);
      expect(find.text('Add a friend'), findsOneWidget);
      final addressField = tester.widget<TextField>(
        find.widgetWithText(TextField, "Friend's address"),
      );
      expect(addressField.controller!.text, 'deep-link.example:8080');
      final codeField = tester.widget<TextField>(
        find.widgetWithText(TextField, "Friend's code"),
      );
      expect(codeField.controller!.text, 'deep-code');
    },
  );

  testWidgets(
    'cold start on a musicat://playlist link (not yet joined) lands on '
    '/playlists with the create/join sheet open and pre-filled, not the '
    'error page',
    (tester) async {
      const invite = PlaylistInvite(id: 'invited-id', name: 'Party Mix');
      final deepLink = InviteUri.build(invite).toString();

      await pumpColdStart(tester, deepLink);

      expect(find.text('Page Not Found'), findsNothing);
      expect(find.widgetWithText(AppBar, 'Playlists'), findsOneWidget);
      expect(find.text('New joint playlist'), findsOneWidget);
      final idField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Joining an existing one? Paste its id'),
      );
      expect(idField.controller!.text, 'invited-id');
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Name'),
      );
      expect(nameField.controller!.text, 'Party Mix');
    },
  );

  testWidgets('cold start on a malformed/unparseable musicat:// link shows the '
      'SnackBar error and lands on the library screen, not a crash or the '
      'error page', (tester) async {
    // Exercises the `on InviteUriException catch` branch specifically —
    // an unrecognized host is a well-formed URI that still fails
    // InviteUri.parseUri.
    const deepLink = 'musicat://something-else?foo=bar';

    await pumpColdStart(tester, deepLink);

    expect(find.text('Page Not Found'), findsNothing);
    expect(find.text('Musicat'), findsOneWidget);
    expect(
      find.text('Unrecognized invite link: "something-else".'),
      findsOneWidget,
    );
  });
}
