import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/presentation/library_providers.dart';
import 'joint_playlist_providers.dart';

Future<void> showAddTrackToJointPlaylistSheet(
  BuildContext context,
  String playlistId,
) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => _AddTrackSheet(playlistId: playlistId),
  );
}

class _AddTrackSheet extends ConsumerWidget {
  const _AddTrackSheet({required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(tracksProvider);

    return SafeArea(
      child: tracksAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, stackTrace) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $error'),
        ),
        data: (tracks) {
          if (tracks.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Your library is empty.'),
            );
          }
          return ListView.builder(
            shrinkWrap: true,
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return ListTile(
                leading: track.coverArtPath != null
                    ? Image.file(
                        File(track.coverArtPath!),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      )
                    : const Icon(Icons.music_note, size: 48),
                title: Text(track.title),
                subtitle: Text(track.artist),
                onTap: () async {
                  try {
                    await addTrackToJointPlaylist(
                      ref,
                      playlistId: playlistId,
                      track: track,
                    );
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Added "${track.title}".')),
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not add: $e')),
                    );
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}
