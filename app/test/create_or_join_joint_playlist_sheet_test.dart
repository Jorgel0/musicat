import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/invite/invite_uri.dart';
import 'package:musicat/features/playlists/presentation/create_or_join_joint_playlist_sheet.dart';

void main() {
  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCreateOrJoinJointPlaylistSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a pasted playlist-invite link fills the join-id field and, since name '
    'is empty, the name field too',
    (tester) async {
      await openSheet(tester);

      final raw = InviteUri.build(
        const PlaylistInvite(id: 'pasted-id', name: 'Pasted Name'),
      ).toString();

      await tester.enterText(
        find.widgetWithText(TextField, 'Or paste an invite link'),
        raw,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Use'));
      await tester.pump();

      final idField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Joining an existing one? Paste its id'),
      );
      expect(idField.controller!.text, 'pasted-id');
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Name'),
      );
      expect(nameField.controller!.text, 'Pasted Name');

      // Never auto-submits.
      expect(find.text('New joint playlist'), findsOneWidget);
    },
  );

  testWidgets(
    "a pasted invite's name never clobbers a name the user already typed",
    (tester) async {
      await openSheet(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'My own name',
      );

      final raw = InviteUri.build(
        const PlaylistInvite(id: 'pasted-id', name: 'Someone else\'s name'),
      ).toString();
      await tester.enterText(
        find.widgetWithText(TextField, 'Or paste an invite link'),
        raw,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Use'));
      await tester.pump();

      final idField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Joining an existing one? Paste its id'),
      );
      expect(idField.controller!.text, 'pasted-id');
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Name'),
      );
      expect(nameField.controller!.text, 'My own name');
    },
  );

  testWidgets(
    'pasting a friend invite (not a playlist invite) shows an error',
    (tester) async {
      await openSheet(tester);

      final raw = InviteUri.build(
        const FriendInvite(address: 'a.example:8080', code: 'x'),
      ).toString();
      await tester.enterText(
        find.widgetWithText(TextField, 'Or paste an invite link'),
        raw,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Use'));
      await tester.pump();

      expect(
        find.text('That link is not a joint-playlist invite.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'showCreateOrJoinJointPlaylistSheet prefillId/prefillName populate the '
    'fields up front',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showCreateOrJoinJointPlaylistSheet(
                    context,
                    prefillId: 'preset-id',
                    prefillName: 'Preset Name',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final idField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Joining an existing one? Paste its id'),
      );
      expect(idField.controller!.text, 'preset-id');
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Name'),
      );
      expect(nameField.controller!.text, 'Preset Name');
    },
  );
}
