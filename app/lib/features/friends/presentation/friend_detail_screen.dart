import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/federation/federation_client.dart';
import '../../../core/network/social/sharing_client.dart';
import 'friends_controller.dart';
import 'musicat_server_config_controller.dart';
import 'shared_track_download.dart';

final _friendSharedTracksProvider =
    FutureProvider.family<List<SharedTrackSummary>, String>((
      ref,
      friendNodeId,
    ) {
      final client = ref.watch(sharingClientProvider);
      if (client == null) return Future.value(const []);
      return client.listFriendSharedTracks(friendNodeId);
    });

final _friendSharedTrackCoverProvider =
    FutureProvider.family<Uint8List?, ({String friendNodeId, String trackId})>((
      ref,
      key,
    ) async {
      final client = ref.watch(sharingClientProvider);
      if (client == null) return null;
      final bytes = await client.downloadSharedTrackCover(
        key.friendNodeId,
        key.trackId,
      );
      return bytes == null ? null : Uint8List.fromList(bytes);
    });

class FriendDetailScreen extends ConsumerWidget {
  const FriendDetailScreen({required this.nodeId, super.key});

  final String nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(friendsControllerProvider).friends;
    FederationFriend? friend;
    for (final entry in friends) {
      if (entry.friend.nodeId == nodeId) {
        friend = entry.friend;
        break;
      }
    }
    final hasRelay = friend?.relayUrl != null;
    final tracksAsync = ref.watch(_friendSharedTracksProvider(nodeId));

    return Scaffold(
      appBar: AppBar(
        title: Text(friend?.displayLabel ?? nodeId),
        actions: [
          IconButton(
            tooltip: 'Edit nickname',
            icon: const Icon(Icons.edit_outlined),
            onPressed: friend == null
                ? null
                : () => _editNickname(context, ref, friend!),
          ),
        ],
      ),
      body: Column(
        children: [
          if (hasRelay)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_queue,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Relay fallback available',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          Expanded(
            child: tracksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) =>
                  Center(child: Text('Could not load shared tracks: $error')),
              data: (tracks) {
                if (tracks.isEmpty) {
                  return const Center(
                    child: Text('Nothing shared with you yet.'),
                  );
                }
                return ListView.builder(
                  itemCount: tracks.length,
                  itemBuilder: (context, index) => _SharedTrackTile(
                    friendNodeId: nodeId,
                    track: tracks[index],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens [_EditNicknameDialog] pre-filled with [friend]'s current
/// [FederationFriend.localNickname], and, unless cancelled, saves whatever
/// the user submitted via [FriendsController.setLocalNickname] — an empty
/// submission clears the nickname, same convention as the old (now
/// removed) "Name (optional)" field in `_AddFriendSheet`.
Future<void> _editNickname(
  BuildContext context,
  WidgetRef ref,
  FederationFriend friend,
) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) =>
        _EditNicknameDialog(initialValue: friend.localNickname),
  );
  if (result == null) return; // Cancelled.
  final trimmed = result.trim();
  await ref
      .read(friendsControllerProvider.notifier)
      .setLocalNickname(friend.nodeId, trimmed.isEmpty ? null : trimmed);
}

/// A small dialog for setting/clearing a friend's purely local nickname —
/// distinct from their own self-chosen [FederationFriend.displayName].
/// Mirrors `promptPlaylistName`'s cancel-vs-submit convention: `null` means
/// cancelled, any other (possibly empty) string means "save this".
class _EditNicknameDialog extends StatefulWidget {
  const _EditNicknameDialog({this.initialValue});

  final String? initialValue;

  @override
  State<_EditNicknameDialog> createState() => _EditNicknameDialogState();
}

class _EditNicknameDialogState extends State<_EditNicknameDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nickname'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Nickname',
          hintText: 'Leave empty to remove',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _SharedTrackTile extends ConsumerStatefulWidget {
  const _SharedTrackTile({required this.friendNodeId, required this.track});

  final String friendNodeId;
  final SharedTrackSummary track;

  @override
  ConsumerState<_SharedTrackTile> createState() => _SharedTrackTileState();
}

class _SharedTrackTileState extends ConsumerState<_SharedTrackTile> {
  bool _downloading = false;

  @override
  Widget build(BuildContext context) {
    final coverAsync = widget.track.hasCoverArt
        ? ref.watch(
            _friendSharedTrackCoverProvider((
              friendNodeId: widget.friendNodeId,
              trackId: widget.track.id,
            )),
          )
        : const AsyncValue<Uint8List?>.data(null);

    return ListTile(
      leading: coverAsync.maybeWhen(
        data: (bytes) => bytes != null
            ? Image.memory(bytes, width: 48, height: 48, fit: BoxFit.cover)
            : const Icon(Icons.music_note, size: 48),
        orElse: () => const Icon(Icons.music_note, size: 48),
      ),
      title: Text(widget.track.title),
      subtitle: Text(
        [
          widget.track.artist,
          if (widget.track.album != null) widget.track.album!,
        ].join(' — '),
      ),
      trailing: _downloading
          ? const SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Download',
              onPressed: _download,
            ),
    );
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      await downloadAndImportSharedTrack(
        ref,
        ownerNodeId: widget.friendNodeId,
        trackId: widget.track.id,
        extension: widget.track.extension,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded "${widget.track.title}".')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not download: $e')));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }
}
