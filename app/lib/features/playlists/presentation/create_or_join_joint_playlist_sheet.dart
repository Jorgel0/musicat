import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/invite/invite_uri.dart';
import '../../../core/invite/qr_scanner_screen.dart';
import '../../friends/presentation/friends_controller.dart';
import 'joint_playlist_providers.dart';

/// Opens the create/join sheet. [prefillId]/[prefillName] pre-fill the
/// join-id and name fields — used when landing here from an already-parsed
/// playlist invite (a deep link or a QR scan elsewhere), same
/// review-before-submitting rule as the friend-invite flow: nothing here
/// auto-submits.
Future<void> showCreateOrJoinJointPlaylistSheet(
  BuildContext context, {
  String? prefillId,
  String? prefillName,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => _CreateOrJoinJointPlaylistSheet(
      prefillId: prefillId,
      prefillName: prefillName,
    ),
  );
}

class _CreateOrJoinJointPlaylistSheet extends ConsumerStatefulWidget {
  const _CreateOrJoinJointPlaylistSheet({this.prefillId, this.prefillName});

  final String? prefillId;
  final String? prefillName;

  @override
  ConsumerState<_CreateOrJoinJointPlaylistSheet> createState() =>
      _CreateOrJoinJointPlaylistSheetState();
}

class _CreateOrJoinJointPlaylistSheetState
    extends ConsumerState<_CreateOrJoinJointPlaylistSheet> {
  late final _nameController = TextEditingController(text: widget.prefillName);
  late final _joinIdController = TextEditingController(text: widget.prefillId);
  final _pasteLinkController = TextEditingController();
  final _selectedNodeIds = <String>{};
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _joinIdController.dispose();
    _pasteLinkController.dispose();
    super.dispose();
  }

  /// Runs [raw] — from a QR scan or the "paste an invite link" field —
  /// through the shared [InviteUri] parser. Fills the join-id field on a
  /// valid playlist invite, and the name field too, but only if it's still
  /// empty — never clobbers something the user already typed.
  void _applyInvite(String raw) {
    setState(() => _error = null);
    final InvitePayload payload;
    try {
      payload = InviteUri.parse(raw);
    } on InviteUriException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    if (payload is! PlaylistInvite) {
      setState(() => _error = 'That link is not a joint-playlist invite.');
      return;
    }
    final invite = payload;
    setState(() {
      _joinIdController.text = invite.id;
      if (invite.name != null && _nameController.text.trim().isEmpty) {
        _nameController.text = invite.name!;
      }
      _pasteLinkController.clear();
    });
  }

  Future<void> _scanInvite() async {
    final raw = await scanQrCode(context, title: "Scan a playlist's invite");
    if (raw == null) return;
    _applyInvite(raw);
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _selectedNodeIds.isEmpty) {
      setState(
        () => _error = 'Enter a name and pick at least one participant.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final joinId = _joinIdController.text.trim();
      await createOrJoinJointPlaylist(
        ref,
        name: name,
        participantNodeIds: _selectedNodeIds.toList(),
        id: joinId.isEmpty ? null : joinId,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            joinId.isEmpty ? 'Created "$name".' : 'Joined "$name".',
          ),
        ),
      );
    } catch (e) {
      setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendsControllerProvider).friends;

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'New joint playlist',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _joinIdController,
              decoration: const InputDecoration(
                labelText: 'Joining an existing one? Paste its id',
                hintText: 'Leave empty to create a new playlist',
              ),
            ),
            const SizedBox(height: 12),
            if (qrScanningSupported) ...[
              OutlinedButton.icon(
                onPressed: _scanInvite,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text("Scan a playlist's QR code"),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _pasteLinkController,
                    decoration: const InputDecoration(
                      labelText: 'Or paste an invite link',
                      hintText: 'musicat://playlist?...',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: OutlinedButton(
                    onPressed: () => _applyInvite(_pasteLinkController.text),
                    child: const Text('Use'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Participants',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (friends.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No friends yet.'),
              )
            else
              ...friends.map(
                (entry) => CheckboxListTile(
                  title: Text(entry.friend.displayName ?? entry.friend.nodeId),
                  value: _selectedNodeIds.contains(entry.friend.nodeId),
                  onChanged: (checked) => setState(() {
                    if (checked ?? false) {
                      _selectedNodeIds.add(entry.friend.nodeId);
                    } else {
                      _selectedNodeIds.remove(entry.friend.nodeId);
                    }
                  }),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
