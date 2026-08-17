import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../friends/presentation/musicat_server_config_controller.dart';
import '../../friends/presentation/shared_track_download.dart';
import 'add_track_to_joint_playlist_sheet.dart';
import 'joint_playlist_providers.dart';

class JointPlaylistDetailScreen extends ConsumerWidget {
  const JointPlaylistDetailScreen({required this.playlistId, super.key});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistAsync = ref.watch(jointPlaylistProvider(playlistId));
    final myNodeId = ref.watch(myNodeIdProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: Text(playlistAsync.value?.name ?? 'Joint playlist'),
        actions: [
          IconButton(
            tooltip: 'Share this playlist\'s id with a friend',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showShareIdDialog(context),
          ),
          IconButton(
            tooltip: 'Sync with participants',
            icon: const Icon(Icons.sync),
            onPressed: () => _sync(context, ref),
          ),
          PopupMenuButton<_Action>(
            onSelected: (action) {
              if (action == _Action.delete) _delete(context, ref);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _Action.delete,
                child: Text('Delete playlist'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showAddTrackToJointPlaylistSheet(context, playlistId),
        child: const Icon(Icons.add),
      ),
      body: playlistAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text('Error: $error')),
        data: (playlist) {
          if (playlist.items.isEmpty) {
            return const Center(
              child: Text('No tracks yet — tap + to add one of yours.'),
            );
          }
          return ListView.builder(
            itemCount: playlist.items.length,
            itemBuilder: (context, index) {
              final item = playlist.items[index];
              final isMine = item.ownerNodeId == myNodeId;
              return ListTile(
                leading: const Icon(Icons.music_note),
                title: Text(item.title),
                subtitle: Text(
                  [
                    item.artist,
                    if (item.album != null) item.album!,
                  ].join(' — '),
                ),
                trailing: isMine
                    ? const Tooltip(
                        message: 'Added by you',
                        child: Icon(Icons.check_circle_outline),
                      )
                    : _DownloadButton(item: item),
              );
            },
          );
        },
      ),
    );
  }

  void _showShareIdDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Playlist id'),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(child: SelectableText(playlistId)),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: playlistId)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    try {
      final result = await syncJointPlaylist(ref, playlistId);
      if (!context.mounted) return;
      final message = result.errors.isEmpty
          ? 'Synced.'
          : 'Synced with issues: ${result.errors.join('; ')}';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not sync: $e')));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    await deleteJointPlaylist(ref, playlistId);
    if (context.mounted) Navigator.of(context).pop();
  }
}

enum _Action { delete }

class _DownloadButton extends ConsumerStatefulWidget {
  const _DownloadButton({required this.item});

  final JointPlaylistItem item;

  @override
  ConsumerState<_DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends ConsumerState<_DownloadButton> {
  bool _downloading = false;

  @override
  Widget build(BuildContext context) {
    if (_downloading) {
      return const SizedBox(
        height: 24,
        width: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download_outlined),
      tooltip: 'Download',
      onPressed: _download,
    );
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      await downloadAndImportSharedTrack(
        ref,
        ownerNodeId: widget.item.ownerNodeId,
        trackId: widget.item.sharedTrackId,
        extension: widget.item.extension,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded "${widget.item.title}".')),
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
