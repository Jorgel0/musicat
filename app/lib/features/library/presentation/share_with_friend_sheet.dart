import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/social/sharing_client.dart';
import '../../friends/presentation/friends_controller.dart';
import '../../friends/presentation/musicat_server_config_controller.dart';
import '../domain/track.dart';

Future<void> showShareWithFriendSheet(BuildContext context, Track track) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ShareWithFriendSheet(track: track),
  );
}

class _ShareWithFriendSheet extends ConsumerWidget {
  const _ShareWithFriendSheet({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(sharingClientProvider);
    if (client == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('Set up your Musicat Server under Friends first.'),
      );
    }

    final friendsState = ref.watch(friendsControllerProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.people),
            title: const Text('All friends'),
            onTap: () => _share(context, client, const {
              'type': 'allFriends',
            }, 'all friends'),
          ),
          const Divider(height: 1),
          if (friendsState.friends.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No friends yet.'),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: friendsState.friends.length,
                itemBuilder: (context, index) {
                  final friend = friendsState.friends[index].friend;
                  final label = friend.displayName ?? friend.nodeId;
                  return ListTile(
                    leading: const Icon(Icons.person),
                    title: Text(label),
                    onTap: () => _share(context, client, {
                      'type': 'friends',
                      'nodeIds': [friend.nodeId],
                    }, label),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _share(
    BuildContext context,
    SharingClient client,
    Map<String, Object?> visibility,
    String targetLabel,
  ) async {
    try {
      await client.shareTrack(
        filePath: track.filePath,
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverArtPath: track.coverArtPath,
        visibility: visibility,
      );
      if (!context.mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Shared "${track.title}" with $targetLabel.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    }
  }
}
