import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'invite_uri.dart';

/// An invite delivered by an Android deep link (`musicat://...`), waiting
/// for the screen it lands on to notice it and pre-fill its flow. See
/// `../routing/app_router.dart`'s top-level `redirect`, which populates
/// this before navigating — the sheet a deep link should open
/// (`_AddFriendSheet`, the create/join joint-playlist sheet) isn't itself a
/// route, so this is the hand-off point between "a link arrived" and "the
/// right screen is mounted and can show it".
sealed class PendingInvite {
  const PendingInvite();
}

final class PendingFriendInvite extends PendingInvite {
  const PendingFriendInvite(this.invite);

  final FriendInvite invite;
}

final class PendingPlaylistInvite extends PendingInvite {
  const PendingPlaylistInvite(this.invite);

  final PlaylistInvite invite;
}

/// A `musicat://` link that failed to parse. Still surfaced — never
/// silently dropped — typically as a one-off SnackBar from whatever screen
/// the redirect lands on by default.
final class PendingInviteError extends PendingInvite {
  const PendingInviteError(this.message);

  final String message;
}

/// Holds at most one not-yet-handled invite. A screen that can act on a
/// given [PendingInvite] subtype reads and clears it via [consume] right
/// after its first frame, so it's only ever acted on once — see
/// `FriendsScreen`/`PlaylistsScreen`.
class PendingInviteController extends Notifier<PendingInvite?> {
  @override
  PendingInvite? build() => null;

  void set(PendingInvite invite) => state = invite;

  /// Returns the current pending invite (if any) and clears it.
  PendingInvite? consume() {
    final current = state;
    state = null;
    return current;
  }
}

final pendingInviteProvider =
    NotifierProvider<PendingInviteController, PendingInvite?>(
      PendingInviteController.new,
    );
