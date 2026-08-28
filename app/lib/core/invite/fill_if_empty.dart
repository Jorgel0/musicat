import 'package:flutter/widgets.dart';

/// Fills [controller] with [value] unless the user has already typed
/// something into it, or [value] itself is absent — used when applying a
/// scanned/pasted invite's *optional* fields (e.g. a display name) so a
/// pre-filled invite never clobbers text the user already entered
/// themselves. Shared by `_AddFriendSheet` and
/// `_CreateOrJoinJointPlaylistSheet`'s near-identical `_applyInvite`
/// methods, which diverged on exactly this rule once already.
void fillIfEmpty(TextEditingController controller, String? value) {
  if (value != null && controller.text.trim().isEmpty) {
    controller.text = value;
  }
}
