import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../friends/presentation/friends_controller.dart';
import 'joint_playlist_providers.dart';

Future<void> showCreateOrJoinJointPlaylistSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _CreateOrJoinJointPlaylistSheet(),
  );
}

class _CreateOrJoinJointPlaylistSheet extends ConsumerStatefulWidget {
  const _CreateOrJoinJointPlaylistSheet();

  @override
  ConsumerState<_CreateOrJoinJointPlaylistSheet> createState() =>
      _CreateOrJoinJointPlaylistSheetState();
}

class _CreateOrJoinJointPlaylistSheetState
    extends ConsumerState<_CreateOrJoinJointPlaylistSheet> {
  final _nameController = TextEditingController();
  final _joinIdController = TextEditingController();
  final _selectedNodeIds = <String>{};
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _joinIdController.dispose();
    super.dispose();
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
